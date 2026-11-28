use super::relabel_auto_background;

#[test]
fn an_automatic_move_is_not_called_manual() {
    let said = "Command was manually backgrounded by user with ID: b1. Output is being written to: /t/b1.output.";
    assert_eq!(
        relabel_auto_background(said),
        "Command was moved to the background (ID: b1). Output is being written to: /t/b1.output."
    );
    assert_eq!(relabel_auto_background("ok"), "ok");
}
