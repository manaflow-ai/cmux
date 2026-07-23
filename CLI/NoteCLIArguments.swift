struct NoteCLIArguments {
    let subcommand: String
    let operands: [String]
    let projectPath: String?
    let text: String?
    let readsStandardInput: Bool
}
