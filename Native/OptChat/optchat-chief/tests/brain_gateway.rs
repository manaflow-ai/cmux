//! An open-source brain has no built-in model gateway: a team host in product code would send
//! every person's brain to a machine they cannot reach (and that is not theirs). With no
//! gateway set, the Chief marks the brain unavailable with the reason `chief brains` shows, and
//! writes no brain home; with one set, the home names that gateway and nothing else.

use optchat_chief::brain_home::{self, BrainSetup};
use optchat_chief::engine::EngineChoice;
use optchat_chief::paths::Paths;
use serde_json::json;

/// The team hosts this product must never name on its own (cmux-chief TEAM_SUBROUTER_URLS).
const TEAM_HOSTS: [&str; 3] = ["cmux-lawrences-mac-mini", "tail137216", "100.89.225.106"];

fn daemon_with_hermes() -> serde_json::Value {
    json!({
        "harnesses": {"hermes": {"argv": ["hermes", "acp"], "family": "hermes"}},
        "optchatDaemonFeatures": {"builtinPresets": true, "brainPresets": true},
    })
}

fn files_under(dir: &std::path::Path) -> Vec<std::path::PathBuf> {
    let mut out = Vec::new();
    for e in std::fs::read_dir(dir).into_iter().flatten().flatten() {
        let p = e.path();
        if p.is_dir() {
            out.extend(files_under(&p));
        } else {
            out.push(p);
        }
    }
    out
}

#[test]
fn a_brain_with_no_gateway_set_is_unavailable_and_names_no_team_host() {
    // SAFETY: this test binary's only test that reads the variable.
    unsafe { std::env::remove_var(brain_home::BASE_URL_ENV) };
    let dir = tempfile::tempdir().unwrap();
    let paths = Paths::new(dir.path());
    let setup = BrainSetup::from_choice(&EngineChoice::default(), &paths);
    let states = brain_home::prepare(&paths, &daemon_with_hermes(), &setup, &|_| {});
    let hermes = &states["hermes"];
    assert_eq!(hermes.state, "unavailable", "{hermes:?}");
    assert_eq!(hermes.reason.as_deref(), Some(brain_home::NO_GATEWAY));
    let listing = brain_home::listing(&paths, Some("hermes"));
    assert!(listing.contains("no model gateway is set"), "{listing}");
    for f in files_under(dir.path()) {
        let text = std::fs::read_to_string(&f).unwrap_or_default();
        for host in TEAM_HOSTS {
            assert!(
                !text.contains(host),
                "{} names the team host {host}",
                f.display()
            );
        }
    }

    // The person's own gateway: the brain is ready and its home names only that gateway.
    let choice = EngineChoice {
        brain_base_url: Some("http://gateway.example:8080".into()),
        ..Default::default()
    };
    let setup = BrainSetup::from_choice(&choice, &paths);
    let states = brain_home::prepare(&paths, &daemon_with_hermes(), &setup, &|_| {});
    assert_eq!(states["hermes"].state, "ready", "{:?}", states["hermes"]);
    let config = std::fs::read_to_string(
        brain_home::dir(&paths, brain_home::brain("hermes").unwrap()).join("config.yaml"),
    )
    .unwrap();
    assert!(
        config.contains("http://gateway.example:8080/v1"),
        "{config}"
    );
    for host in TEAM_HOSTS {
        assert!(
            !config.contains(host),
            "config.yaml names the team host {host}"
        );
    }
}
