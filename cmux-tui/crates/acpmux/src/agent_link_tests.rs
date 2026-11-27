//! The reader's own vectors run in `cmux-web-route`; these pin what acpmux reads through the
//! re-export (PR footers, `opaque_agent_id`'s `web_query`).
use super::*;

#[test]
fn acpmux_reads_a_footer_link_through_the_reexport() {
    let line = "Agent session: [my-vm](https://cmux.com/deeplink/agent?harness=claude&session=01a16c8c-54ec-71b2-a0fa-125d1404dd72&host=my-vm)";
    let link: AgentLink = find(line).unwrap().unwrap();
    assert_eq!(link.harness, "claude");
    assert_eq!(link.host.as_deref(), Some("my-vm"));
    assert_eq!(
        web_query(line),
        Some("harness=claude&session=01a16c8c-54ec-71b2-a0fa-125d1404dd72&host=my-vm")
    );
}
