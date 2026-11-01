//! Chief tool packs (plans/cmux-next/chief-toolpacks-DESIGN.md): every
//! service a Chief signs in to is data (`toolpacks/NAME/pack.toml` +
//! SKILL.md) over one small core, not a Rust module of its own (Lawrence,
//! 2026-10-24: "GitHub should not be its own Rust module").

use std::os::unix::fs::PermissionsExt;
use std::path::Path;
use std::process::Command;

use optchat_chief::prompt::Tools;
use optchat_chief::session_dir::{SessionSetup, write};
use optchat_chief::toolpacks::{self, FileStore, Store};

/// A pack no Rust knows about: a CLI `acme` that reads `ACME_TOKEN`, and
/// git credentials for `git.acme.dev`.
const ACME: &str = r#"
name = "acme"
title = "Acme"
description = "the acme CLI"
health = ["acme", "whoami"]

[tool]
bin = "acme"

[auth]
methods = ["paste"]

[check]
url = "https://api.acme.dev/me"
login_field = "me.handle"

[inject]
env = ["ACME_TOKEN", "ACME_API_KEY"]
git_host = "git.acme.dev"
"#;

fn put(dir: &Path, name: &str, text: &str) {
    std::fs::create_dir_all(dir.join(name)).unwrap();
    std::fs::write(dir.join(name).join("pack.toml"), text).unwrap();
}

#[test]
fn shipped_packs_parse_and_github_keeps_a607s_constants() {
    let names: Vec<&str> = toolpacks::BUILTIN.iter().map(|b| b.0).collect();
    assert_eq!(names, ["browser", "cmux", "gdocs", "github", "vercel"]);
    for (name, toml, skill) in toolpacks::BUILTIN {
        let p = toolpacks::parse(toml).unwrap_or_else(|e| panic!("{name}: {e}"));
        assert_eq!(p.name, name);
        assert!(p.managed, "{name} carries cmux-managed");
        assert!(
            optchat_chief::skills::front_matter(skill).is_some(),
            "{name} SKILL.md"
        );
    }
    let gh = toolpacks::builtin("github").unwrap();
    assert_eq!(gh.tool.bin, "gh");
    assert_eq!(gh.keychain_service(), "cmux.chief.github");
    let auth = gh.auth.as_ref().unwrap();
    let device = auth.device.as_ref().unwrap();
    assert_eq!(device.client_id, "178c6fc778ccc68e1d6a");
    assert_eq!(device.scopes, "repo read:org gist workflow");
    assert_eq!(device.window_minutes, 180);
    assert_eq!(auth.skill.as_deref(), Some("github-signin"));
    let inject = gh.inject.as_ref().unwrap();
    assert_eq!(inject.env, ["GH_TOKEN"]);
    assert_eq!(inject.git_host.as_deref(), Some("github.com"));
    assert_eq!(gh.share.as_ref().unwrap().command[0], "gh");
    // The same files as before packs: an existing sign-in keeps working.
    let home = Path::new("/h");
    assert_eq!(
        toolpacks::secret_file(home, "github"),
        Path::new("/h/optchat/secrets/github.json")
    );
    assert_eq!(
        toolpacks::status_path(home, "github"),
        Path::new("/h/optchat/github.json")
    );
    // The second service is data only.
    let vercel = toolpacks::builtin("vercel").unwrap();
    assert_eq!(vercel.inject.as_ref().unwrap().env, ["VERCEL_TOKEN"]);
    assert!(
        vercel.share.is_none(),
        "sharing the person's login is opt-in"
    );
    // Packs that only teach a CLI have no secret and no wrapper.
    assert!(toolpacks::builtin("cmux").unwrap().inject.is_none());
}

#[test]
fn own_beats_shared_beats_shipped_and_a_users_copy_is_kept() {
    let dir = tempfile::tempdir().unwrap();
    let home = dir.path().join("default");
    let shared = toolpacks::shared_dir(&home);
    assert_eq!(shared, dir.path().join("toolpacks"));
    assert_eq!(toolpacks::chief_dir(&home), home.join("toolpacks"));

    let written = toolpacks::install_builtin(&shared).unwrap();
    assert_eq!(written, ["browser", "cmux", "gdocs", "github", "vercel"]);
    assert!(
        toolpacks::install_builtin(&shared).unwrap().is_empty(),
        "no rewrite"
    );
    // A user copy (no marker) survives an update; a stale managed one is rewritten.
    let mine = "name = \"vercel\"\ntitle = \"My Vercel\"\n[tool]\nbin = \"vercel\"\n";
    put(&shared, "vercel", mine);
    put(
        &shared,
        "cmux",
        "# cmux-managed: true\nname = \"cmux\"\ntitle = \"old\"\n[tool]\nbin = \"cmux\"\n",
    );
    assert_eq!(toolpacks::install_builtin(&shared).unwrap(), ["cmux"]);
    assert_eq!(
        std::fs::read_to_string(shared.join("vercel/pack.toml")).unwrap(),
        mine
    );

    put(&shared, "acme", ACME);
    put(
        &toolpacks::chief_dir(&home),
        "acme",
        &ACME.replace("title = \"Acme\"", "title = \"Acme (mine)\""),
    );
    put(
        &shared,
        "github",
        "# cmux-managed: true\nname = \"github\"\nenabled = false\n[tool]\nbin = \"gh\"\n",
    );
    let packs = toolpacks::load(&home);
    let title = |n: &str| packs.iter().find(|p| p.name == n).map(|p| p.title.clone());
    assert_eq!(title("vercel").as_deref(), Some("My Vercel"));
    assert_eq!(title("acme").as_deref(), Some("Acme (mine)"));
    assert_eq!(title("github"), None, "an override can turn a pack off");
    assert_eq!(title("browser").as_deref(), Some("Browser"));
}

#[test]
fn a_pack_that_could_reach_a_shell_is_refused() {
    for bad in [
        ACME.replace("bin = \"acme\"", "bin = \"acme; rm -rf ~\""),
        ACME.replace("\"ACME_TOKEN\"", "\"ACME TOKEN\""),
        ACME.replace("git.acme.dev", "git.acme.dev\"; evil"),
        ACME.replace("name = \"acme\"", "name = \"../acme\""),
    ] {
        assert!(toolpacks::parse(&bad).is_err(), "{bad}");
    }
    assert!(toolpacks::parse(ACME).is_ok());
}

#[test]
fn tokens_are_checked_per_pack_and_kept_private_per_pack() {
    let acme = toolpacks::parse(ACME).unwrap();
    assert!(acme.token_ok("acme_0123456789abcdefABCDEF.x-1"));
    assert!(!acme.token_ok("-acme0123456789abcdefABCDEF"));
    assert!(!acme.token_ok("acme_0123456789abcdef -w evil"));
    assert!(!acme.token_ok("short"));

    let dir = tempfile::tempdir().unwrap();
    let s = FileStore {
        path: toolpacks::secret_file(dir.path(), "acme"),
        pack: acme.clone(),
    };
    let t = "acme_0123456789abcdefABCDEF0123456789";
    s.set(t).unwrap();
    assert_eq!(s.get().as_deref(), Some(t));
    assert_eq!(
        std::fs::metadata(&s.path).unwrap().permissions().mode() & 0o777,
        0o600
    );
    assert_eq!(
        std::fs::metadata(s.path.parent().unwrap())
            .unwrap()
            .permissions()
            .mode()
            & 0o777,
        0o700
    );
    assert!(s.set("not a token").is_err());
    s.clear().unwrap();
    assert_eq!(s.get(), None);
}

/// Runs `command`, retrying while a parallel test's fork holds a script
/// open for write (ETXTBSY).
fn output(command: &mut Command) -> std::process::Output {
    for _ in 0..50 {
        match command.output() {
            Err(e) if e.kind() == std::io::ErrorKind::ExecutableFileBusy => {
                std::thread::sleep(std::time::Duration::from_millis(20));
            }
            result => return result.unwrap(),
        }
    }
    command.output().unwrap()
}

#[test]
fn a_data_only_pack_reaches_its_cli_and_git_on_every_turn() {
    let dir = tempfile::tempdir().unwrap();
    let home = dir.path().join("default");
    let paths = optchat_chief::paths::Paths::new(&home);
    paths.create().unwrap();
    put(&toolpacks::shared_dir(&home), "acme", ACME);
    let setup = SessionSetup {
        exe: "/x/optchat-chief".into(),
        env: Default::default(),
        instructions: None,
        tools: Tools::Cli(paths.bin.join("chief").display().to_string()),
        user_env: Default::default(),
        profile_tool: false,
        chiefs_tool: false,
    };
    write(&paths, &setup).unwrap();

    // gh and git exactly as before, through the GitHub pack.
    let gh = std::fs::read_to_string(paths.bin.join("gh")).unwrap();
    assert!(gh.contains("\"$self_dir/chief\" pack token github"), "{gh}");
    assert!(gh.contains("GH_TOKEN=$t"));
    assert!(gh.contains("exec gh \"$@\""));
    let helper = std::fs::read_to_string(paths.bin.join("git-credential-chief-github")).unwrap();
    assert!(
        helper.contains("\"$self_dir/gh\" auth git-credential \"$@\""),
        "{helper}"
    );
    // Vercel and Acme with no Rust of their own.
    // Vercel ships off (the default set is github, cmux, browser); one switch turns it on.
    assert!(!paths.bin.join("vercel").exists());
    toolpacks::set_enabled(&home, "vercel", true).unwrap();
    write(&paths, &setup).unwrap();
    assert!(paths.bin.join("vercel").exists());
    assert!(paths.bin.join("git-credential-chief-acme").exists());
    assert!(
        !paths.bin.join("cmux").exists(),
        "a pack with no secret leaves its CLI alone"
    );

    let settings: serde_json::Value = serde_json::from_slice(
        &std::fs::read(paths.session.join(".claude").join("settings.json")).unwrap(),
    )
    .unwrap();
    let env = &settings["env"];
    assert_eq!(env["GIT_CONFIG_COUNT"], "4");
    let keys: Vec<&str> = (0..4)
        .map(|i| env[format!("GIT_CONFIG_KEY_{i}")].as_str().unwrap())
        .collect();
    assert!(
        keys.contains(&"credential.https://github.com.helper"),
        "{keys:?}"
    );
    assert!(
        keys.contains(&"credential.https://git.acme.dev.helper"),
        "{keys:?}"
    );

    // The wrapper asks the Chief for the token on each call and runs the real CLI with it.
    std::fs::write(
        paths.bin.join("chief"),
        "#!/bin/sh\n[ \"$1 $2 $3\" = \"pack token acme\" ] && echo acme_0123456789abcdefABCDEF && exit 0\nexit 1\n",
    )
    .unwrap();
    let real = dir.path().join("real");
    std::fs::create_dir_all(&real).unwrap();
    std::fs::write(
        real.join("acme"),
        "#!/bin/sh\necho \"argv=$* token=${ACME_TOKEN-unset} key=${ACME_API_KEY-unset}\"\n",
    )
    .unwrap();
    std::fs::set_permissions(real.join("acme"), std::fs::Permissions::from_mode(0o755)).unwrap();
    let path = format!("{}:{}:/usr/bin:/bin", paths.bin.display(), real.display());
    let out = output(
        Command::new(paths.bin.join("acme"))
            .arg("whoami")
            .env("PATH", &path),
    );
    assert_eq!(
        String::from_utf8_lossy(&out.stdout).trim(),
        "argv=whoami token=acme_0123456789abcdefABCDEF key=acme_0123456789abcdefABCDEF"
    );
    // git gets the same token for its host, and nothing for other actions.
    let mut git = Command::new(paths.bin.join("git-credential-chief-acme"));
    git.arg("get").env("PATH", &path);
    let out = output(&mut git);
    assert_eq!(
        String::from_utf8_lossy(&out.stdout),
        "username=x-access-token\npassword=acme_0123456789abcdefABCDEF\n"
    );
    let out = output(
        Command::new(paths.bin.join("git-credential-chief-acme"))
            .arg("store")
            .env("PATH", &path),
    );
    assert!(out.stdout.is_empty());
}

#[test]
fn github_reads_as_before_through_its_pack() {
    use serde_json::json;
    let gh = toolpacks::builtin("github").unwrap();
    let own = json!({"signed_in": true, "own": true, "kind": "device", "login": "octo",
        "scopes": ["repo", "workflow"], "expires_at": null});
    assert_eq!(
        toolpacks::describe(&gh, &own),
        "signed in as octo (device, this Chief's own; repo workflow)"
    );
    let mac = json!({"signed_in": true, "own": false, "kind": "mac", "login": "octo", "scopes": [],
        "expires_at": 1_796_083_200_000u64});
    assert_eq!(
        toolpacks::describe(&gh, &mac),
        "signed in as octo (mac, the Mac's gh; fine-grained, expires 2026-12-01)"
    );
    assert_eq!(
        toolpacks::describe(&gh, &json!({"signed_in": false})),
        "not signed in to GitHub (chief github login)"
    );
    let c = toolpacks::card(&gh, "ABCD-1234", "https://github.com/login/device");
    assert_eq!(
        c,
        "Sign in to GitHub for this Chief: copy the code `ABCD-1234`, open the page below and approve.\n[github.com/login/device](https://github.com/login/device)"
    );
}
