use serde_json::Value;

/// What a tool call or an ask carries of the agent's own: its input, output and content, and the
/// ask's options. Whatever is inside them (a display-shaped field included) is the agent's data,
/// shown and approved as it is.
const AGENT_DATA: [&str; 4] = ["rawInput", "rawOutput", "content", "options"];

/// Drops the display line (`toolCall._meta.acpmux.display`) of every permission request in
/// `value`, wherever one sits: a pending prompt, an event record, the agent's own ask. What a peer
/// daemon sends (its pending prompts, its event records, its replies) carries no display line of
/// its own to this daemon's clients, since a peer on an older build passes on whatever its agent
/// wrote there. Only this daemon's own stamp (`Hub::stamp_permission_display`) reaches a person;
/// a peer's prompt shows its raw title, as before display lines. Nothing else changes: the
/// agent's data (`AGENT_DATA`) is never looked into.
pub fn drop_display_lines(value: &mut Value) {
    match value {
        Value::Object(map) => {
            if let Some(acpmux) = map
                .get_mut("toolCall")
                .and_then(|call| call.get_mut("_meta"))
                .and_then(|meta| meta.get_mut("acpmux"))
                .and_then(Value::as_object_mut)
            {
                acpmux.remove("display");
            }
            for (key, child) in map.iter_mut() {
                if !AGENT_DATA.contains(&key.as_str()) {
                    drop_display_lines(child);
                }
            }
        }
        Value::Array(items) => items.iter_mut().for_each(drop_display_lines),
        _ => {}
    }
}
