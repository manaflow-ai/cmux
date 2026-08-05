/// Latest immutable input delivered to the native Vault table.
@MainActor
struct SessionIndexTableApplyInput {
    let rows: [SessionIndexTableRow]
    let environment: SessionIndexTableEnvironmentSnapshot
}
