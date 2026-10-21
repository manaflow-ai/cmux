//! `workspaces::link_subagents`: every mention of a known subagent becomes its
//! link, wherever it sits in the Markdown (bold, headings, list items, tables).

use optchat_chief::workspaces::link_subagents;

const PARENT: &str = "optchat-chief:0123abcd";

fn link(text: &str) -> String {
    link_subagents(text, PARENT, |id| match id {
        "a81" => Some("s-81".to_owned()),
        "a82" => Some("s-82".to_owned()),
        _ => None,
    })
}

const A81: &str = "[a81](cmux://chief/0123abcd/session/s-81)";

#[test]
fn an_id_inside_bold_is_linked() {
    assert_eq!(
        link("- **a81: focus after dropping a file.** Next."),
        format!("- **{A81}: focus after dropping a file.** Next.")
    );
}

#[test]
fn an_id_inside_a_heading_is_linked() {
    assert_eq!(link("## a81 status"), format!("## {A81} status"));
    assert_eq!(link("### **a81**"), format!("### **{A81}**"));
}

#[test]
fn an_id_inside_italic_and_a_table_cell_is_linked() {
    assert_eq!(link("_a81_ done"), format!("_{A81}_ done"));
    assert_eq!(link("| a81 | ok |"), format!("| {A81} | ok |"));
}

#[test]
fn unknown_ids_code_and_existing_links_stay_as_written() {
    assert_eq!(link("a99 and `a81`"), "a99 and `a81`");
    assert_eq!(link("foo_a81 and a81_x"), "foo_a81 and a81_x");
    assert_eq!(
        link("__a82__"),
        "__[a82](cmux://chief/0123abcd/session/s-82)__"
    );
    assert_eq!(link(A81), A81);
}
