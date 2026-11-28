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

#[test]
fn an_over_max_folder_is_big_and_writes_at_most_max_plus_one_bytes() {
    let base = tempfile::tempdir().unwrap();
    let src = base.path().join("p");
    // Incompressible-ish data well over the bound.
    let data: Vec<u8> = (0..400_000u32).map(|i| (i.wrapping_mul(2654435761) >> 13) as u8).collect();
    std::fs::create_dir_all(&src).unwrap();
    std::fs::write(src.join("blob"), &data).unwrap();
    // The script's temp dir is removed on exit: watch what it writes through a TMPDIR we own.
    let tmp = base.path().join("tmp");
    std::fs::create_dir_all(&tmp).unwrap();
    let script = PACK_SCRIPT.replace(
        "if [ \"$n\" -gt \"$max\" ]; then echo \"big $n\"; exit 0; fi",
        "if [ \"$n\" -gt \"$max\" ]; then echo \"big $n\"; echo \"$n\" >\"$TMPDIR/size\"; exit 0; fi",
    );
    let input = format!("{}\n1000\n", src.display());
    let out = std::process::Command::new("/bin/sh")
        .arg("-c")
        .arg(&script)
        .env("TMPDIR", &tmp)
        .stdin(std::process::Stdio::piped())
        .stdout(std::process::Stdio::piped())
        .spawn()
        .and_then(|mut c| {
            use std::io::Write as _;
            c.stdin.take().unwrap().write_all(input.as_bytes())?;
            c.wait_with_output()
        })
        .unwrap();
    assert_eq!(String::from_utf8_lossy(&out.stdout).trim(), "big 1001");
    assert_eq!(std::fs::read_to_string(tmp.join("size")).unwrap().trim(), "1001");
}

#[test]
fn the_wt_mirrors_folder_stays_behind() {
    let base = tempfile::tempdir().unwrap();
    let src = base.path().join("p");
    write(&src.join("a.txt"), "a");
    write(&src.join(".wt-mirrors/x/pack"), "m");
    let Packed::Files(pack) = pack_folder(None, &src).unwrap() else { panic!("not packed") };
    let there =
        PathBuf::from(unpack_folder("", &base.path().join("t").to_string_lossy(), &pack).unwrap());
    assert!(there.join("a.txt").exists());
    assert!(!there.join(".wt-mirrors").exists());
}
