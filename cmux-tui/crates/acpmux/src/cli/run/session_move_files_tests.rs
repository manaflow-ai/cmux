use super::*;

fn write(p: &Path, text: &str) {
    std::fs::create_dir_all(p.parent().unwrap()).unwrap();
    std::fs::write(p, text).unwrap();
}

#[test]
fn a_plain_folder_goes_with_its_files_and_leaves_secrets() {
    let base = tempfile::tempdir().unwrap();
    let src = base.path().join("notes");
    write(&src.join("a.txt"), "a");
    write(&src.join("sub/b.md"), "b");
    write(&src.join(".env"), "SECRET=1");
    write(&src.join("sub/key.pem"), "k");
    write(&src.join("node_modules/x/index.js"), "x");
    write(&src.join(".ssh/id_rsa"), "r");
    let Packed::Files(pack) = pack_folder(None, &src).unwrap() else { panic!("not packed") };

    let target = base.path().join("target/notes");
    let there = unpack_folder("", &target.to_string_lossy(), &pack).unwrap();
    let there = PathBuf::from(there);
    assert_eq!(there, target.canonicalize().unwrap());
    assert_eq!(std::fs::read_to_string(there.join("a.txt")).unwrap(), "a");
    assert_eq!(std::fs::read_to_string(there.join("sub/b.md")).unwrap(), "b");
    assert!(!there.join(".env").exists());
    assert!(!there.join("sub/key.pem").exists());
    assert!(!there.join("node_modules").exists());
    assert!(!there.join(".ssh").exists());
}

#[test]
fn a_folder_already_holding_files_is_never_written_into() {
    let base = tempfile::tempdir().unwrap();
    let src = base.path().join("p");
    write(&src.join("new.txt"), "n");
    let Packed::Files(pack) = pack_folder(None, &src).unwrap() else { panic!("not packed") };
    let target = base.path().join("t/p");
    write(&target.join("mine.txt"), "m");
    let there = PathBuf::from(unpack_folder("", &target.to_string_lossy(), &pack).unwrap());
    assert_ne!(there, target.canonicalize().unwrap());
    assert!(there.join("new.txt").exists());
    assert!(!target.join("new.txt").exists());
    assert_eq!(std::fs::read_to_string(target.join("mine.txt")).unwrap(), "m");
}

#[test]
fn a_missing_folder_is_only_a_path_and_a_big_one_is_named() {
    let base = tempfile::tempdir().unwrap();
    assert_eq!(pack_folder(None, &base.path().join("nope")).unwrap(), Packed::Missing);
    // The bound is read from stdin: a zero bound makes any pack too big.
    let src = base.path().join("p");
    write(&src.join("a.txt"), "a");
    let input = format!("{}\n0\n", src.display());
    let out = run_here(PACK_SCRIPT, input.as_bytes()).unwrap();
    assert!(out.stdout.starts_with("big "), "{out:?}");
}
