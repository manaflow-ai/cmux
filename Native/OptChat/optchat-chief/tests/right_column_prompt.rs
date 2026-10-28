//! Every agent the Chief runs shows what it opens in one column right of
//! its chat (Lawrence 2026-10-18: "always default to a split column to the
//! right (so it's left and right and easier to manage)"), sorts its
//! workspaces into sidebar groups ("use groups more aggressively so that you
//! can organize and the user feels less overwhelmed") and pushes straight to
//! the feature branch ("we don't want to really use [PRs] at all"), and work counts only once
//! it is on that branch (2026-10-19: every subagent's work must really land
//! on feat-cmux-next).

use optchat_chief::prompt::{Tools, chief_system_text, subagent_system_text};

fn prompts() -> Vec<(&'static str, String)> {
    let cli = Tools::Cli("/opt/chief".into());
    vec![
        (
            "chief mcp",
            chief_system_text(None, &Tools::Mcp, false, false),
        ),
        ("chief cli", chief_system_text(None, &cli, true, true)),
        ("subagent mcp", subagent_system_text(None, &Tools::Mcp)),
        ("subagent cli", subagent_system_text(None, &cli)),
    ]
}

#[test]
fn every_agent_prompt_keeps_one_column_right_of_the_chat() {
    for (name, text) in prompts() {
        let flat = text.split_whitespace().collect::<Vec<_>>().join(" ");
        assert!(
            flat.contains("your chat on the left and one column"),
            "{name}: no right-column rule"
        );
        assert!(
            flat.contains("split --right --viewport-width 0.5"),
            "{name}: no way to make the column"
        );
        assert!(
            flat.contains("split down or add another column unless the user asks"),
            "{name}: no limit to one column"
        );
    }
}

#[test]
fn every_agent_prompt_groups_workspaces_and_pushes_without_pull_requests() {
    for (name, text) in prompts() {
        let flat = text.split_whitespace().collect::<Vec<_>>().join(" ");
        assert!(
            flat.contains("goes into a group named by its topic"),
            "{name}: no group rule"
        );
        assert!(
            flat.contains("cmux workspace group create --name NAME"),
            "{name}: no way to make a group"
        );
        assert!(
            flat.contains("Never close or rename the user's workspaces to group them"),
            "{name}"
        );
        assert!(
            flat.contains("no pull requests unless the user asks"),
            "{name}: no push rule"
        );
        assert!(flat.contains("never force"), "{name}");
    }
}

#[test]
fn every_agent_prompt_counts_work_as_done_only_when_it_landed() {
    for (name, text) in prompts() {
        let flat = text.split_whitespace().collect::<Vec<_>>().join(" ");
        assert!(
            flat.contains("a scratch or work branch is not landed")
                || flat.contains("a scratch, work or red branch is not landed"),
            "{name}: no landing rule"
        );
        assert!(
            flat.contains("sha range"),
            "{name}: report has no landed sha range"
        );
    }
}

#[test]
fn each_rule_appears_once_in_each_prompt() {
    for (name, text) in prompts() {
        for rule in ["- Where to show things:", "- Sidebar groups:", "- Git:"] {
            assert_eq!(text.matches(rule).count(), 1, "{name}: {rule}");
        }
    }
}

/// Lawrence 2026-10-20: every Chief, local or cloud, operates "the browser on
/// the right", with a balance between doing browser steps itself and giving
/// them to subagents (plans/cmux-next/chief-browser-use-DESIGN.md).
#[test]
fn every_chief_prompt_drives_the_browser_on_the_right_and_splits_the_work() {
    for (name, text) in prompts()
        .into_iter()
        .filter(|(name, _)| name.starts_with("chief"))
    {
        let flat = text.split_whitespace().collect::<Vec<_>>().join(" ");
        assert!(
            flat.contains("cmux browser right"),
            "{name}: no right-browser verb"
        );
        assert!(flat.contains("--agent"), "{name}: the cursor is not named");
        assert!(
            flat.contains("under about 8 actions"),
            "{name}: no do-it-yourself bound"
        );
        assert!(flat.contains("to a subagent"), "{name}: no hand-off rule");
        assert!(
            flat.contains("lease_held"),
            "{name}: no one-driver-per-tab rule"
        );
    }
}

#[test]
fn every_agent_prompt_never_drives_a_tab_another_agent_holds() {
    for (name, text) in prompts() {
        let flat = text.split_whitespace().collect::<Vec<_>>().join(" ");
        assert!(
            flat.contains("Never drive a tab another agent drives"),
            "{name}"
        );
        assert_eq!(text.matches("- Browser:").count(), 1, "{name}");
    }
}

/// Lawrence 2026-10-20: when work is done, the Chief shows its diff, page or
/// file beside its chat by default, from the report's `<show>` block.
#[test]
fn the_chief_prompt_shows_done_work_in_the_right_column() {
    let text = chief_system_text(None, &Tools::Mcp, false, false);
    let flat = text.split_whitespace().collect::<Vec<_>>().join(" ");
    assert!(flat.contains("- After work:"), "no after-work rule");
    assert!(flat.contains("ends with a <show> block"), "no show block");
    assert!(flat.contains("show.afterReport"), "no setting named");
}

/// 2026-10-20: Chief subagents ran `git fetch origin feat-cmux-next` and
/// `git log --all` in the shared main checkout ~/Projects/cmux on the
/// person's Mac; on its partial clone each one fetched ~378k objects, the
/// Mac's biggest load that night. Every agent works in its own worktree and
/// reads remote state through the GitHub API.
#[test]
fn every_agent_prompt_keeps_git_off_the_shared_checkout() {
    for (name, text) in prompts() {
        let flat = text.split_whitespace().collect::<Vec<_>>().join(" ");
        assert!(
            flat.contains("in your own worktree"),
            "{name}: no own-worktree rule"
        );
        assert!(
            flat.contains("never in a repository's main checkout"),
            "{name}: no main-checkout rule"
        );
        assert!(
            flat.contains("gh pr view"),
            "{name}: no GitHub API for remote state"
        );
        assert!(
            flat.contains("never run `git log --all`"),
            "{name}: no whole-history rule"
        );
    }
}

/// 2026-10-20 on cosmic-gray: agents killed git processes they had found by
/// name, among them the clone's repair refetch, which another agent had
/// started. An agent signals only what it started and tracks.
#[test]
fn every_agent_prompt_kills_only_its_own_processes() {
    for (name, text) in prompts() {
        let flat = text.split_whitespace().collect::<Vec<_>>().join(" ");
        assert!(
            flat.contains("signal only a process you started and still track"),
            "{name}: no own-process rule"
        );
        assert!(
            flat.contains("never one found by name or command line"),
            "{name}: no rule against matching by name"
        );
        assert!(flat.contains("`pkill`"), "{name}: pkill not named");
    }
}
