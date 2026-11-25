//! `acpmux uniichat-agent login` (also `cmux acp uniichat-agent login`, and what
//! `cmux harness login unii` runs): signs this computer in to a UniiChat server
//! the way the `unii` terminal's `unii login` does (Term.ts `login_run`), so a
//! Mac with no `unii` program can use the built-in UniiChat harness (first-run
//! finding 2: "Sign in to Unii…" ran `unii login`, which a clean Mac does not
//! have).
//!
//! The flow is UniiChat's own: `/api/hello` says whether the server bills and
//! takes GitHub names; a random key made here goes with the typed address to
//! `/api/login`, which mails a link (or answers a GitHub page) and a code to
//! type on that page; `/api/wait` with the key as the bearer answers once the
//! link was opened (408: still waiting, 410: the link expired). The key is then
//! the sign-in: it is written, owner-only, to the token file the adapter and
//! `unii` both read (`$UNII_HOME/<host>/token`).

use anyhow::{Context, Result, anyhow, bail};
use base64::Engine;
use serde_json::{Value, json};
use std::io::Write;
use std::path::Path;
use std::time::Duration;
use tokio::io::AsyncBufReadExt;

use crate::uniichat_endpoint::{Endpoint, Options};

/// How long one `/api/wait` may hang before it is asked again (the server
/// answers 408 sooner; this only bounds a connection that went quiet).
const WAIT_REQUEST: Duration = Duration::from_secs(10 * 60);

/// The pause before a wait that failed (no answer, or neither 408 nor done)
/// is asked again: a deliberate backoff, not a poll (408 asks again at once).
const WAIT_RETRY: Duration = Duration::from_secs(2);

/// Signs in to the server `options` (else `$UNII_URL`, else uniichat.com)
/// names, reading the address from standard input.
pub async fn run(options: Options) -> Result<()> {
    let endpoint = Endpoint::resolve(
        &options,
        std::env::var("UNII_URL").ok(),
        std::env::var("UNII_HOME").ok(),
        dirs::home_dir(),
    )
    .map_err(anyhow::Error::msg)?;
    let _ = rustls::crypto::ring::default_provider().install_default();
    let client = crate::happy_dial::http_client()
        .connect_timeout(Duration::from_secs(15))
        .user_agent(concat!("acpmux-uniichat/", env!("CARGO_PKG_VERSION")))
        .build()?;
    let base = &endpoint.base;
    // A server that says nothing of itself bills and takes GitHub names (Term.ts).
    let hello: Value =
        match client.get(format!("{base}/api/hello")).timeout(Duration::from_secs(15)).send().await
        {
            Ok(res) => res.json().await.unwrap_or(Value::Null),
            Err(_) => Value::Null,
        };
    let flag = |name: &str| hello.get(name).and_then(Value::as_bool).unwrap_or(true);
    if flag("bills") {
        println!(
            "Signing in, you accept the terms ({base}/terms.html) and the privacy policy ({base}/privacy.html)."
        );
    }
    let key = new_key()?;
    let mut lines = tokio::io::BufReader::new(tokio::io::stdin()).lines();
    let (who, answer) = loop {
        print!("{}", if flag("github") { "Email or @github: " } else { "Email: " });
        std::io::stdout().flush().ok();
        let Some(line) = lines.next_line().await? else { bail!("no address typed") };
        let who = line.trim().to_owned();
        if who.is_empty() {
            continue;
        }
        let res = client
            .post(format!("{base}/api/login"))
            .timeout(Duration::from_secs(30))
            .json(&json!({"who": who, "key": key}))
            .send()
            .await
            .map_err(|e| anyhow!("no connection to {base}: {e}"))?;
        let status = res.status();
        let answer: Value =
            res.json().await.unwrap_or_else(|_| json!({"error": format!("HTTP {status}")}));
        match answer.get("error") {
            Some(error) => match error.as_str() {
                Some(why) => println!("{why}"),
                None => println!("{error}"),
            },
            None => break (who, answer),
        }
    };
    let text = |name: &str| answer.get(name).and_then(Value::as_str).filter(|s| !s.is_empty());
    match text("url") {
        Some(url) => {
            open_browser(url);
            println!("Sign in with GitHub in the browser: {url}");
        }
        None => println!("A sign-in link is on its way to {who}. Open it."),
    }
    if let Some(code) = text("code") {
        println!("On the page it opens, type this code: {code}");
    }
    wait(&client, base, &key).await?;
    save_token(&endpoint.token_file, &key)?;
    println!("Signed in to UniiChat ({}).", endpoint.host);
    Ok(())
}

/// Waits until the link was opened: `/api/wait` answers ok, or 410 when the
/// link expired. Only the server ends the wait.
async fn wait(client: &reqwest::Client, base: &str, key: &str) -> Result<()> {
    loop {
        let res = client
            .get(format!("{base}/api/wait"))
            .bearer_auth(key)
            .timeout(WAIT_REQUEST)
            .send()
            .await;
        let Ok(res) = res else {
            tokio::time::sleep(WAIT_RETRY).await;
            continue;
        };
        let status = res.status().as_u16();
        let ok = status == 200
            && res.json::<Value>().await.ok().and_then(|v| v.get("ok")?.as_bool()) == Some(true);
        match status {
            _ if ok => return Ok(()),
            410 => bail!("the sign-in link expired: sign in again"),
            408 => {}
            _ => tokio::time::sleep(WAIT_RETRY).await,
        }
    }
}

/// 32 random bytes, base64url without padding (Term.ts's key).
fn new_key() -> Result<String> {
    let mut bytes = [0u8; 32];
    getrandom::fill(&mut bytes).map_err(|e| anyhow!("the OS random generator: {e}"))?;
    Ok(base64::engine::general_purpose::URL_SAFE_NO_PAD.encode(bytes))
}

/// Writes the token owner-only (its folder too), replacing an older one. Through `home_fs`, as
/// every write a path from the home may reach (`home_writers_by_path_tests.rs`): outside the
/// home it goes by path, as before.
fn save_token(path: &Path, key: &str) -> Result<()> {
    let folder = path.parent().context("the token file has no folder")?;
    crate::home_fs::create_dir_all(folder, 0o700)
        .with_context(|| format!("create {}", folder.display()))?;
    let mut file = crate::home_fs::OpenOptions::new()
        .write(true)
        .create(true)
        .truncate(true)
        .mode(0o600)
        .open(path)
        .with_context(|| format!("write {}", path.display()))?;
    // An older token file keeps its mode through `open`: make it owner-only.
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        file.set_permissions(std::fs::Permissions::from_mode(0o600))?;
    }
    file.write_all(key.as_bytes())?;
    Ok(())
}

/// Opens the GitHub sign-in page: in a cmux terminal `open` is cmux's own
/// opener (it shows the page in cmux); a failure only leaves the printed link.
fn open_browser(url: &str) {
    let opener = if cfg!(target_os = "macos") { "open" } else { "xdg-open" };
    // `open` hands the URL over and exits; waiting for it reaps it.
    let _ = std::process::Command::new(opener)
        .arg(url)
        .stdin(std::process::Stdio::null())
        .stdout(std::process::Stdio::null())
        .stderr(std::process::Stdio::null())
        .status();
}
