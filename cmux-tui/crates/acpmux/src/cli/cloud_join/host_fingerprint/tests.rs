#[test]
fn a_fingerprint_is_stable_hashed_and_differs_per_machine() {
    let first = super::of("0123456789abcdef0123456789abcdef");
    assert_eq!(first, super::of("0123456789abcdef0123456789abcdef"));
    assert_ne!(first, super::of("fedcba9876543210fedcba9876543210"));
    assert_eq!(first.len(), 64);
    assert!(!first.contains("0123456789abcdef0123456789abcdef"));
}
