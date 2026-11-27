use super::*;

#[test]
fn each_app_lists_send_inbox_ls_and_last_and_names_the_other_app() {
    for me in desktop_bridge::APPS {
        let tools = tools(*me);
        let names: Vec<_> =
            tools.as_array().unwrap().iter().map(|t| t["name"].as_str().unwrap()).collect();
        assert_eq!(names, ["send", "inbox", "ls", "last"]);
        for other in desktop_bridge::APPS.iter().filter(|a| a != &me) {
            assert!(tools[0]["description"].as_str().unwrap().contains(other.address));
        }
        assert!(!tools[0]["description"].as_str().unwrap().contains(me.address));
    }
}
