struct RemoteHookPlan: Encodable {
    let stdoutBase64: String
    let stderrBase64: String
    let exitCode: Int32
    let mutations: [RemoteHookMutation]

    enum CodingKeys: String, CodingKey {
        case mutations
        case stdoutBase64 = "stdout_base64"
        case stderrBase64 = "stderr_base64"
        case exitCode = "exit_code"
    }
}
