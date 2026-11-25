use super::*;

#[test]
fn mem_total_reads_kib_and_refuses_other_units() {
    assert_eq!(mem_total("MemTotal:        8029384 kB\nMemFree: 1 kB\n"), Some(8029384 * 1024));
    assert_eq!(mem_total("MemFree: 1 kB\n"), None);
    assert_eq!(mem_total("MemTotal: 8 MB\n"), None);
}

#[test]
fn a_two_cpu_machine_says_its_size_and_what_to_do_about_it() {
    let f = Facts {
        cpus: Some(2),
        memory_bytes: Some(8_000_000_000),
        disk_total_bytes: Some(64_000_000_000),
        disk_free_bytes: Some(41_400_000_000),
        ..Facts::default()
    };
    let text = paragraph(&f);
    for fact in ["2 CPUs", "8.0 GB of memory", "64 GB of disk", "41 GB free", "cargo -j", "free -h"]
    {
        assert!(text.contains(fact), "{fact:?} missing from {text:?}");
    }
    assert!(!text.contains("sccache"));
    assert!(!text.contains("fork"));
}

#[test]
fn capabilities_are_said_only_when_this_machine_has_them() {
    let f = Facts { compiler_cache: true, sub_session_forks: true, ..Facts::default() };
    let text = paragraph(&f);
    assert!(text.contains("sccache"), "{text}");
    assert!(text.contains("start_session with worktree: true"), "{text}");
    assert!(!text.contains("This machine has"), "no size was read: {text}");
}

#[test]
fn nothing_read_says_nothing() {
    assert_eq!(paragraph(&Facts::default()), "");
}

#[test]
fn reading_this_machine_never_panics() {
    let f = Facts::read(Path::new("/"));
    assert!(f.cpus.is_some_and(|n| n >= 1));
}
