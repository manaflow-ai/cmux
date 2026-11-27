/// Latest immutable input delivered by the SwiftUI Vault table bridge.
@MainActor
struct SessionIndexTableApplyInput {
    let rows: [SessionIndexTableRow]
    let environment: SessionIndexTableEnvironmentSnapshot
}
