use super::*;

#[test]
fn guest_handoff_requires_an_explicit_labs_opt_in() {
    assert!(!enabled(&Settings::Missing));
    assert!(!enabled(&Settings::Unreadable("invalid JSONC".into())));
    for doc in [
        json!({}),
        json!({"labs.previewFeatures": false}),
        json!({"labs.previewFeatures": "true"}),
        json!({"labs.previewFeatures": false, "labs": {"previewFeatures": true}}),
    ] {
        assert!(!enabled(&Settings::Parsed(doc)));
    }
    for doc in [json!({"labs.previewFeatures": true}), json!({"labs": {"previewFeatures": true}})] {
        assert!(enabled(&Settings::Parsed(doc)));
    }
    let all = tools_with_artifacts(false);
    assert!(!crate::mcp_hint::names(&tools_with_preview(&all, false)).any(|n| n == NAME));
    let preview = tools_with_preview(&all, true);
    assert!(crate::mcp_hint::names(&preview).any(|n| n == NAME));
    // Switching off rejects even a client that cached the advertised tool.
    assert!(arguments(&json!({"capsule": "Continue the task"}), false).is_err());
}

#[test]
fn guest_handoff_carries_the_capsule_with_existing_guest_policy_on_every_destination() {
    let capsule = "Goal: fix the parser.\nDecided: preserve comments.\nNext: run its tests. 🦀";
    for app in ["claude-desktop", "claude-code", "codex"] {
        for machine in ["local", "auto", "paired-mac", "cloud-1"] {
            for harness in ["claude", "codex"] {
                let args = arguments(
                    &json!({
                        "capsule": capsule, "prompt": "must not replace the capsule",
                        "harness": harness, "machine": machine, "folder": "/project",
                        "name": "Continue parser", "showInCmux": true
                    }),
                    true,
                )
                .unwrap();
                let (name, argv, prompt) = new_argv(app, &args).unwrap();
                assert_eq!(name, "continue-parser");
                assert_eq!(prompt, capsule);
                assert!(!argv.iter().any(|a| a == capsule));
                let value = |flag: &str| &argv[argv.iter().position(|a| a == flag).unwrap() + 1];
                assert_eq!(value("--policy"), "ask");
                assert_eq!(value("--machine"), machine);
                assert_eq!(value("--model"), harness);
                assert_eq!(value("--tag"), &format!("origin={app}"));
                assert_eq!(value("--from"), crate::desktop_link::App::parse(app).unwrap().label());
                assert!(argv.iter().any(|a| a == "--require-asking"));
                assert!(args.get("capsule").is_none());
            }
        }
    }
}

#[test]
fn guest_handoff_refuses_empty_or_oversized_capsules_without_truncation() {
    for args in [
        json!({}),
        json!({"capsule": null}),
        json!({"capsule": 1}),
        json!({"capsule": ""}),
        json!({"capsule": " \n\t"}),
    ] {
        assert!(arguments(&args, true).is_err(), "{args}");
    }
    let exact = "🦀".repeat(crate::hub::MAX_CAPSULE_BYTES / 4);
    let args = arguments(&json!({"capsule": exact}), true).unwrap();
    assert_eq!(args["prompt"].as_str().unwrap().len(), crate::hub::MAX_CAPSULE_BYTES);
    assert!(arguments(&json!({"capsule": format!("{exact}x")}), true).is_err());
}

#[test]
fn guest_handoff_schema_requires_the_summary_and_preserves_target_controls() {
    let tool = tool();
    assert_eq!(tool["name"], NAME);
    assert_eq!(tool["inputSchema"]["required"], json!(["capsule"]));
    let props = &tool["inputSchema"]["properties"];
    assert!(props.get("prompt").is_none());
    for key in ["harness", "machine", "folder", "name", "showInCmux"] {
        assert_eq!(props[key], new_tool()["inputSchema"]["properties"][key]);
    }
    let args = arguments(&json!({"capsule": "Continue", "harness": "unreviewed"}), true).unwrap();
    assert!(new_argv("codex", &args).is_err());
}
