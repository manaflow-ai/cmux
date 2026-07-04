func toastVersionKey(for installing: UpdateState.Installing) -> String? {
    guard let stagedVersion = installing.stagedVersion, !stagedVersion.isEmpty else { return nil }
    return stagedVersion
}
