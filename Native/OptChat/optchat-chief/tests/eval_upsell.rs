//! Chief fast evals, group `upsell` (deterministic, no model call). When a
//! task needs a paid plan or credits, every Chief has the shipped
//! `paid-plans` skill (`cmux billing checkout`, Stripe Checkout, nothing is
//! charged until the user pays) and its prompt says when to use it.

use optchat_chief::prompt::{Tools, chief_system_text};
use optchat_chief::skills;

#[test]
fn the_paid_plans_skill_ships_with_the_checkout_command_and_the_never_rules() {
    let dir = std::env::temp_dir().join(format!("optchat-upsell-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&dir);
    let shared = skills::shared_dir(&dir.join("default"));
    let written = skills::install_builtin(&shared).unwrap();
    assert!(written.contains(&"paid-plans".to_owned()), "{written:?}");
    let loaded = skills::load(&shared, &skills::chief_dir(&dir.join("default")));
    let skill = loaded
        .iter()
        .find(|s| s.name == "paid-plans")
        .expect("paid-plans loads");
    for word in ["cloud.plan.required", "credits"] {
        assert!(
            skill.description.contains(word),
            "{word}: {}",
            skill.description
        );
    }
    let text = std::fs::read_to_string(&skill.path).unwrap();
    for want in [
        "cmux billing checkout --plan <plus|pro|max|team>",
        "Tell the user in one line: what the plan adds and its price",
        "nothing is charged until they pay",
        "Never say you bought, paid for or upgraded anything",
        "never twice for one ask",
        "Never ask for or type card numbers",
    ] {
        assert!(text.contains(want), "skill lacks {want:?}");
    }
    let _ = std::fs::remove_dir_all(&dir);
}

#[test]
fn the_chief_prompt_says_when_to_send_a_checkout() {
    let cli = Tools::Cli("/opt/chief".into());
    for (name, text) in [
        ("mcp", chief_system_text(None, &Tools::Mcp, false, false)),
        ("cli", chief_system_text(None, &cli, true, true)),
    ] {
        let flat = text.split_whitespace().collect::<Vec<_>>().join(" ");
        for want in [
            "`paid-plans` skill",
            "`cloud.plan.required`",
            "cmux billing checkout",
            "nothing is charged until the user pays",
        ] {
            assert!(flat.contains(want), "{name}: prompt lacks {want:?}");
        }
    }
}

/// Eval baseline 2026-10-26 (upsell-a675-cloud-plan-required, 0/3): the Chief
/// left out the price, offered "or I run it another way" as a choice, and
/// waited for "tell me when you paid". The rules: the price in the line, no
/// alternative offered as a choice, and a sleep() that checks the plan and
/// resumes the blocked step by itself.
#[test]
fn a_checkout_line_has_the_price_offers_no_choice_and_resumes_by_itself() {
    let text = chief_system_text(None, &Tools::Mcp, false, false)
        .split_whitespace()
        .collect::<Vec<_>>()
        .join(" ");
    for want in [
        "what the plan adds and its monthly price (Pro $50, Max $200, Team $60 a seat)",
        "never offer another way as a choice",
        "`cmux billing status --json`",
        "resume the blocked task yourself",
    ] {
        assert!(text.contains(want), "prompt lacks {want:?}");
    }
    let skill = std::fs::read_to_string(concat!(
        env!("CARGO_MANIFEST_DIR"),
        "/skills/paid-plans/SKILL.md"
    ))
    .unwrap();
    let skill = skill.split_whitespace().collect::<Vec<_>>().join(" ");
    for want in [
        "Pro $50/month",
        "never offer another way as a choice",
        "call `sleep(600",
    ] {
        assert!(skill.contains(want), "skill lacks {want:?}");
    }
}
