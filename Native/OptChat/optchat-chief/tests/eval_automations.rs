//! Chief fast evals, group `automations` (deterministic, no model call;
//! plans/cmux-next/chief-automations-DESIGN.md). A recurring or triggered
//! job, or one that must run while the user's computers sleep, is a cmux
//! automation the Chief makes itself with `cmux automation` (`--target cloud`
//! for the Cloud Chief, else this Mac's runner); sleep() is not a scheduler.

use optchat_chief::prompt::{Tools, chief_system_text};

fn flat(text: &str) -> String {
    text.split_whitespace().collect::<Vec<_>>().join(" ")
}

#[test]
fn the_chief_prompt_sends_recurring_and_sleeping_computer_jobs_to_the_cloud_chief() {
    let cli = Tools::Cli("/opt/chief".into());
    for (name, text) in [
        ("mcp", chief_system_text(None, &Tools::Mcp, false, false)),
        ("cli", chief_system_text(None, &cli, true, true)),
    ] {
        let flat = flat(&text);
        for want in [
            "- Jobs: a recurring or triggered job",
            "while the user's computers sleep",
            "`cmux automation create NAME --target cloud --prompt",
            "results post in the Cloud Chief's chat",
            "needs this Mac's files or apps",
            "`cmux automation runner install`",
            "`cmux automation list --target cloud`",
            "never delete an automation unless the user asked",
            "sleep() is only for looking again at your own work",
        ] {
            assert!(flat.contains(want), "{name}: prompt lacks {want:?}");
        }
    }
}

#[test]
fn a_plan_refusal_from_a_job_is_sent_on_as_one_checkout_line() {
    let text = flat(&chief_system_text(None, &Tools::Mcp, false, false));
    assert!(
        text.contains("`automation.plan.required`"),
        "no plan refusal rule"
    );
    assert!(
        text.contains("send its checkout link to the user in one line"),
        "no one-line link rule"
    );
}
