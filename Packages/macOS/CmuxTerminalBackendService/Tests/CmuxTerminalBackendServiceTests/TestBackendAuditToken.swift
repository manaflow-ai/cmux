import CmuxTerminalBackend

func testBackendAuditToken(
    processID: UInt32,
    userID: UInt32,
    processIDVersion: UInt32 = 1
) -> BackendAuditToken {
    BackendAuditToken(
        word0: userID,
        word1: userID,
        word2: 0,
        word3: userID,
        word4: 0,
        word5: processID,
        word6: 0,
        word7: processIDVersion
    )
}
