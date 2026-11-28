use super::*;

const TABLE: &str = "22 1 8:1 / / rw,relatime - ext4 /dev/vda1 rw\n\
        40 22 0:41 / /home/cmux/work/empty\\040folder rw,nosuid,nodev - fuse.cmux cmux-projection:/Users/p/Desktop/empty%20folder rw,user_id=1000\n\
        41 22 0:42 / /home/cmux/work/old rw,nosuid,nodev - fuse.cmux cmux-projection rw,user_id=1000\n\
        42 22 0:43 / /home/cmux/work/other rw,nosuid,nodev - fuse.sshfs host:/x rw\n";

#[test]
fn an_empty_projected_folder_names_its_mac_folder_and_how_edits_come_back() {
    let path = Path::new("/home/cmux/work/empty folder");
    let answer = describe_with(path, TABLE, None);
    assert_eq!(answer["projected"], true);
    assert_eq!(answer["mac_folder"], "/Users/p/Desktop/empty folder");
    assert_eq!(answer["edits_reach_mac"], "on_bring_back");
    assert_eq!(answer["git"], false);
    let summary = answer["summary"].as_str().unwrap();
    assert!(summary.contains("/Users/p/Desktop/empty folder"), "{summary}");
    assert!(
        summary.contains("Bring Back") && summary.contains("not a git repository"),
        "{summary}"
    );
    assert!(!summary.contains("nothing here is copied"), "{summary}");
}

#[test]
fn a_folder_below_a_projection_is_in_it_and_an_old_mount_has_no_mac_name() {
    let below = describe_with(Path::new("/home/cmux/work/empty folder/src"), TABLE, None);
    assert_eq!(below["projected"], true);
    assert_eq!(below["mount_point"], "/home/cmux/work/empty folder");
    let old =
        describe_with(Path::new("/home/cmux/work/old"), TABLE, Some("/home/cmux/work/old".into()));
    assert_eq!(old["projected"], true);
    assert_eq!(old["mac_folder"], Value::Null);
    assert!(old["summary"].as_str().unwrap().contains("a git repository"));
}

#[test]
fn a_projected_git_folder_says_so_and_still_comes_back_on_bring_back() {
    let path = Path::new("/home/cmux/work/empty folder");
    let answer = describe_with(path, TABLE, Some(path.into()));
    assert_eq!(answer["projected"], true);
    assert_eq!(answer["git"], true);
    let summary = answer["summary"].as_str().unwrap();
    assert!(summary.contains("is a git repository") && summary.contains("Bring Back"), "{summary}");
}

#[test]
fn the_machines_own_folder_and_another_fuse_mount_are_no_projection() {
    for path in ["/home/cmux/work/plain", "/home/cmux/work/other"] {
        let answer = describe_with(Path::new(path), TABLE, None);
        assert_eq!(answer["projected"], false, "{path}");
        assert_eq!(answer["edits_reach_mac"], "never", "{path}");
    }
}

#[test]
fn a_malformed_name_is_no_projection_claim() {
    let table = "40 22 0:41 / /w rw - fuse.cmux cmux-projectionX rw\n41 22 0:41 / /v rw - fuse.cmux cmux-projection:%zz rw\n";
    assert_eq!(projection_of(Path::new("/w"), table), None);
    assert_eq!(projection_of(Path::new("/v"), table), None);
}
