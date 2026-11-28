//! `optchat-chief cloud ...`: enroll a brain host as an install of the user,
//! pick (or create) the chief it answers as, and check that a chief token
//! can be minted. Secrets never go on the command line: the one-time session
//! token comes from `CMUX_CLOUD_SESSION_TOKEN`, the install key stays in the
//! 0600 install file.

use std::path::PathBuf;
use std::sync::Arc;

use serde_json::{Value, json};

use super::auth::{self, Http, InstallFile, InstallTokens, TokenSource, UreqHttp};
use super::pair::{self, PairOptions};
use crate::cli::{Flags, env};

const USAGE: &str = "optchat-chief cloud pair --install FILE --api-base URL [--name N] [--chief default] [--wait-chief SECS]
    pair with the user's account: prints a code to approve in the app (Server > Add Server…), then finds the chief placed here
optchat-chief cloud enroll --install FILE --api-base URL   make the install key, print its install.register params
optchat-chief cloud register --install FILE [--name N] [--device D]   fallback to pair: register it (CMUX_CLOUD_SESSION_TOKEN: the user's session token, once)
optchat-chief cloud chief --install FILE [--create] [--name N]  pick the default chief (or create one) and its main conversation
optchat-chief cloud status --install FILE                     what the file holds, and a test chief token";

fn install_path(flags: &Flags) -> Result<PathBuf, String> {
    flags
        .value("install")
        .map(PathBuf::from)
        .or_else(|| env("OPTCHAT_CLOUD_INSTALL").map(PathBuf::from))
        .ok_or_else(|| USAGE.to_owned())
}

/// Runs a `cloud` verb; returns what to print.
pub fn run(flags: &Flags) -> Result<String, String> {
    run_with(flags, Arc::new(UreqHttp))
}

pub fn run_with(flags: &Flags, http: Arc<dyn Http>) -> Result<String, String> {
    let path = install_path(flags)?;
    match flags.words.get(1).map(String::as_str) {
        Some("pair") => {
            let api = match flags.value("api-base") {
                Some(api) => api.to_owned(),
                None if path.exists() => InstallFile::load(&path)?.api_base_url,
                None => return Err("pair needs --api-base URL".into()),
            };
            let default_fallback = match flags.value("chief") {
                None => false,
                Some("default") => true,
                Some(other) => return Err(format!("--chief {other}: only `default`")),
            };
            let mut opts = PairOptions {
                name: flags.value("name").map(str::to_owned),
                default_fallback,
                ..PairOptions::default()
            };
            if let Some(secs) = flags.value("wait-chief") {
                let secs: u64 = secs
                    .parse()
                    .map_err(|_| format!("--wait-chief {secs}: seconds"))?;
                opts.wait_chief = std::time::Duration::from_secs(secs);
            }
            pair::pair(http, &path, &api, &opts, &mut std::io::stdout())
        }
        Some("enroll") => {
            if path.exists() {
                return Err(format!(
                    "{} exists; enroll makes a new key only once",
                    path.display()
                ));
            }
            let api = flags
                .value("api-base")
                .ok_or("enroll needs --api-base URL")?;
            if !(api.starts_with("https://")
                || api.starts_with("http://127.0.0.1")
                || api.starts_with("http://localhost"))
            {
                return Err(format!(
                    "--api-base {api}: an https origin (http only on loopback)"
                ));
            }
            let file = InstallFile::generate(api)?;
            file.save(&path)?;
            Ok(format!(
                "wrote {}\ninstall.register params:\n{}",
                path.display(),
                serde_json::to_string_pretty(&file.register_params("Chief brain", &host_name()))
                    .unwrap()
            ))
        }
        Some("register") => {
            let mut file = InstallFile::load(&path)?;
            if let Some(install) = &file.install {
                return Err(format!(
                    "{} is registered already ({install})",
                    path.display()
                ));
            }
            let session = env("CMUX_CLOUD_SESSION_TOKEN")
                .ok_or("register needs CMUX_CLOUD_SESSION_TOKEN (the user's session token; it is not stored)")?;
            let name = flags.value("name").unwrap_or("Chief brain");
            let device = flags
                .value("device")
                .map(str::to_owned)
                .unwrap_or_else(host_name);
            let reply = http.post(
                &format!("{}/v1/ops", file.api_base_url),
                &json!({"op": "install.register", "params": file.register_params(name, &device),
                        "idempotency_key": format!("brain-register-{}", thumb(&file))}),
                Some(&session),
            )?;
            if reply.get("ok") != Some(&Value::Bool(true)) {
                return Err(format!(
                    "install.register: {}",
                    reply.get("error").cloned().unwrap_or(reply)
                ));
            }
            let install = reply
                .pointer("/value/id")
                .and_then(Value::as_str)
                .ok_or("install.register returned no install id")?;
            // UserDO answers on its stream `user:<id>`.
            let user = reply
                .get("stream")
                .and_then(Value::as_str)
                .and_then(|s| s.strip_prefix("user:"))
                .ok_or("install.register returned no user stream")?;
            file.install = Some(install.to_owned());
            file.user = Some(user.to_owned());
            file.save(&path)?;
            Ok(format!("registered install {install} for {user}"))
        }
        Some("chief") => {
            let mut file = InstallFile::load(&path)?;
            let tokens = InstallTokens::new(file.clone(), http.clone());
            let lease = tokens.mint(None)?;
            let api = file.api_base_url.clone();
            let listed = auth::read(&*http, &api, &lease.access_token, "chief.list", json!({}))?;
            let chief = listed
                .get("chiefs")
                .and_then(Value::as_array)
                .and_then(|all| {
                    all.iter()
                        .filter(|c| c.get("archived_at").is_none_or(Value::is_null))
                        .find(|c| c.get("is_default") == Some(&Value::Bool(true)))
                        .cloned()
                });
            let chief = match chief {
                Some(c) => c,
                None if flags.value("create").is_some()
                    || flags.words.iter().any(|w| w == "--create") =>
                {
                    let name = flags.value("name").unwrap_or("Chief");
                    auth::op(
                        &*http,
                        &api,
                        &lease.access_token,
                        "chief.create",
                        json!({"display_name": name, "is_default": true}),
                        &format!("brain-chief-{}", file.install.clone().unwrap_or_default()),
                    )?
                }
                None => {
                    return Err(
                        "the user has no active default chief; pass --create to make one".into(),
                    );
                }
            };
            let id = chief
                .get("id")
                .and_then(Value::as_str)
                .ok_or("chief without an id")?;
            let main = chief
                .get("main_conversation")
                .and_then(Value::as_str)
                .ok_or("chief without a main conversation")?;
            file.chief = Some(id.to_owned());
            file.conversation = Some(main.to_owned());
            file.save(&path)?;
            Ok(format!("chief {id}, main conversation {main}"))
        }
        Some("status") => {
            let file = InstallFile::load(&path)?;
            let mut out = format!(
                "api {}\ninstall {}\nuser {}\nhost {}\nteam {}\nchief {}\nconversation {}\n",
                file.api_base_url,
                file.install.as_deref().unwrap_or("-"),
                file.user.as_deref().unwrap_or("-"),
                file.host.as_deref().unwrap_or("-"),
                file.team.as_deref().unwrap_or("-"),
                file.chief.as_deref().unwrap_or("-"),
                file.conversation.as_deref().unwrap_or("-"),
            );
            if file.install.is_some() {
                let tokens = InstallTokens::new(file.clone(), http);
                match tokens.mint(file.chief.as_deref()) {
                    Ok(lease) => {
                        out.push_str(&format!("token ok, expires at {} (ms)\n", lease.expires_at))
                    }
                    Err(e) => out.push_str(&format!("token FAILED: {e}\n")),
                }
            }
            Ok(out)
        }
        _ => Err(USAGE.to_owned()),
    }
}

fn host_name() -> String {
    std::process::Command::new("/bin/hostname")
        .arg("-s")
        .output()
        .ok()
        .map(|o| String::from_utf8_lossy(&o.stdout).trim().to_owned())
        .filter(|s| !s.is_empty())
        .unwrap_or_else(|| "brain".into())
}

fn thumb(file: &InstallFile) -> String {
    file.public_jwk
        .get("x")
        .and_then(Value::as_str)
        .unwrap_or("")
        .chars()
        .take(16)
        .collect()
}
