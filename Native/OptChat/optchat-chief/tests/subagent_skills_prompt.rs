//! Leo, 2026-11-23: "i think we personally have a LOOOOT of good-ass scripts
//! and skills for our stuff... let's go improve the base chief." The skills
//! cmux ships (`~/.cmux/chief/skills`) reach the Chief's subagents too, not
//! only the Chief, so a subagent reads the recipe instead of working it out.

use optchat_chief::prompt::{Tools, subagent_system_text};

#[test]
fn every_subagent_prompt_points_at_the_shipped_skills() {
    for tools in [Tools::Mcp, Tools::Cli("/opt/chief".into())] {
        let text = subagent_system_text(None, &tools);
        let flat = text.split_whitespace().collect::<Vec<_>>().join(" ");
        assert!(
            flat.contains("`~/.cmux/chief/skills/<name>/SKILL.md`"),
            "no skills folder:\n{text}"
        );
        assert!(
            flat.contains("read a skill's SKILL.md before you do what its description names"),
            "no read-first rule:\n{text}"
        );
    }
}
