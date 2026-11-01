use super::*;
use crate::config::{HarnessKind, HarnessProfile};

fn profile(argv: &[&str]) -> HarnessProfile {
    serde_json::from_value(serde_json::json!({ "argv": argv })).unwrap()
}

fn auto(id: &str, argv: &[&str]) -> IconSpec {
    detected(id, None, &profile(argv), id)
}

#[test]
fn an_icon_value_is_an_emoji_a_symbol_a_mark_or_a_file() {
    assert_eq!(IconValue::parse("🦊"), Ok(IconValue::Emoji("🦊".into())));
    assert_eq!(IconValue::parse("👩‍💻"), Ok(IconValue::Emoji("👩‍💻".into())));
    assert_eq!(IconValue::parse("🇯🇵"), Ok(IconValue::Emoji("🇯🇵".into())));
    assert_eq!(IconValue::parse("❤️"), Ok(IconValue::Emoji("❤️".into())));
    assert_eq!(IconValue::parse("hammer.fill"), Ok(IconValue::Symbol("hammer.fill".into())));
    assert_eq!(IconValue::parse("sparkles"), Ok(IconValue::Symbol("sparkles".into())));
    assert_eq!(IconValue::parse("sf:goose"), Ok(IconValue::Symbol("goose".into())));
    assert_eq!(IconValue::parse("goose"), Ok(IconValue::Brand("goose".into())));
    assert_eq!(IconValue::parse("Codex"), Ok(IconValue::Brand("codex".into())));
    assert_eq!(IconValue::parse("terminal"), Ok(IconValue::Glyph("terminal".into())));
    assert_eq!(IconValue::parse("acme.svg"), Ok(IconValue::File("acme.svg".into())));
    assert_eq!(IconValue::parse("/x/Logo.PNG"), Ok(IconValue::File("/x/Logo.PNG".into())));
    for bad in ["", "Not An Icon!", "🦊🦊", "a🦊", "Hammer.Fill", "x..y", ".x"] {
        assert!(IconValue::parse(bad).is_err(), "{bad:?} parsed");
    }
}

#[test]
fn an_unset_icon_is_the_mark_of_the_agent_the_harness_runs() {
    let brand = |spec: IconSpec| match spec {
        IconSpec::Brand { brand, source } => (brand, source),
        other => panic!("no brand: {other:?}"),
    };
    assert_eq!(brand(auto("claude-sr2", &["claude"])), ("claude".into(), IconSource::Id));
    assert_eq!(
        brand(auto("work", &["/opt/bin/codex-acp"])),
        ("openai".into(), IconSource::Command)
    );
    assert_eq!(
        brand(auto("g", &["npx", "-y", "@google/gemini-cli@0.9.0", "--experimental-acp"])),
        ("gemini".into(), IconSource::Command)
    );
    assert_eq!(brand(auto("b", &["uvx", "--from", "x", "goose"])).0, "goose");
    assert_eq!(brand(auto("o", &["pnpm", "dlx", "opencode-ai@latest", "acp"])).0, "opencode");
    let family = detected("mine", None, &profile(&["/bin/sh"]), "amp");
    assert_eq!(brand(family), ("amp".into(), IconSource::Family));
}

#[test]
fn a_harness_no_mark_names_gets_a_stable_monogram() {
    let spec = detected("zeta-bot", Some("Zeta Bot"), &profile(&["/x/zeta"]), "zeta-bot");
    let IconSpec::Monogram { text, hue: h, source } = spec else { panic!("{spec:?}") };
    assert_eq!((text.as_str(), source), ("ZB", IconSource::Default));
    assert_eq!(h, hue("zeta-bot"));
    assert!(h < 360);
    assert_ne!(hue("zeta-bot"), hue("zeta-bob"), "neighbours get different colors");
    assert_eq!(monogram("acme"), "A");
    assert_eq!(monogram("Acme Agent"), "AA");
    assert_eq!(monogram("--"), "?");
    let terminal = HarnessProfile { kind: HarnessKind::Terminal, ..profile(&["/x/tui"]) };
    assert!(matches!(detected("tui", None, &terminal, "tui"), IconSpec::Glyph { .. }));
}

#[test]
fn a_declared_icon_wins_and_a_broken_file_falls_back() {
    let p = profile(&["claude"]);
    let declared = |value| LoadedIcon { value: Some(value), image: None };
    assert_eq!(
        resolve("c", None, &p, "claude", Some(&declared(IconValue::Emoji("🦊".into())))),
        IconSpec::Emoji { text: "🦊".into(), source: IconSource::Profile }
    );
    assert_eq!(
        resolve("c", None, &p, "claude", Some(&declared(IconValue::Brand("codex".into())))),
        IconSpec::Brand { brand: "openai".into(), source: IconSource::Profile }
    );
    // The file was missing: the profile still has an icon.
    assert_eq!(
        resolve("c", None, &p, "claude", Some(&declared(IconValue::File("gone.png".into())))),
        IconSpec::Brand { brand: "claude".into(), source: IconSource::Command }
    );
}

#[test]
fn an_icon_file_must_be_the_image_it_says() {
    assert!(check_image_bytes("image/png", b"\x89PNG\r\n\x1a\nrest").is_ok());
    assert!(check_image_bytes("image/png", b"GIF89a").is_err());
    assert!(check_image_bytes("image/svg+xml", b"<svg viewBox='0 0 1 1'/>").is_ok());
    assert!(check_image_bytes("image/svg+xml", b"<svg><script>x()</script></svg>").is_err());
    assert!(check_image_bytes("image/svg+xml", b"<svg onload=\"x()\"/>").is_err());
}
