import Foundation

extension CMUXCLI {
    func ensureUseCheckout(
        repository: CmuxUseRepository,
        checkoutURL: URL
    ) throws -> CmuxUseCheckoutResult {
        let gitPath = try resolveGitExecutable()
        let fm = FileManager.default
        let parentURL = checkoutURL.deletingLastPathComponent()
        try fm.createDirectory(at: parentURL, withIntermediateDirectories: true, attributes: nil)

        var isDirectory: ObjCBool = false
        let exists = fm.fileExists(atPath: checkoutURL.path, isDirectory: &isDirectory)
        if !exists {
            let result = CLIProcessRunner.runProcess(
                executablePath: gitPath,
                arguments: ["clone", repository.cloneURL, checkoutURL.path]
            )
            guard result.status == 0 else {
                throw CLIError(message: processFailureMessage(
                    String(
                        localized: "cli.use.error.downloadRepositoryFailed",
                        defaultValue: "Failed to download extension repository"
                    ),
                    result: result
                ))
            }
            return CmuxUseCheckoutResult(url: checkoutURL, action: "cloned")
        }

        guard isDirectory.boolValue else {
            throw CLIError(message: String(
                localized: "cli.use.error.checkoutPathNotDirectory",
                defaultValue: "Extension checkout path exists and is not a directory: \(checkoutURL.path)"
            ))
        }

        let gitDirectoryURL = checkoutURL.appendingPathComponent(".git", isDirectory: true)
        guard fm.fileExists(atPath: gitDirectoryURL.path) else {
            throw CLIError(message: String(
                localized: "cli.use.error.checkoutNotGitRepository",
                defaultValue: "Extension checkout exists but is not a git repository: \(checkoutURL.path)"
            ))
        }

        let remoteResult = CLIProcessRunner.runProcess(
            executablePath: gitPath,
            arguments: ["-C", checkoutURL.path, "remote", "get-url", "origin"]
        )
        guard remoteResult.status == 0 else {
            throw CLIError(message: processFailureMessage(
                String(
                    localized: "cli.use.error.inspectCheckoutFailed",
                    defaultValue: "Failed to inspect existing extension checkout"
                ),
                result: remoteResult
            ))
        }
        let remoteURL = remoteResult.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        guard CmuxUseSupport.gitRemote(remoteURL, matches: repository) else {
            throw CLIError(message: String(
                localized: "cli.use.error.checkoutOriginMismatch",
                defaultValue: "Existing extension checkout origin does not match the requested repository"
            ))
        }

        let pullResult = CLIProcessRunner.runProcess(
            executablePath: gitPath,
            arguments: ["-C", checkoutURL.path, "pull", "--ff-only"]
        )
        guard pullResult.status == 0 else {
            throw CLIError(message: processFailureMessage(
                String(
                    localized: "cli.use.error.updateRepositoryFailed",
                    defaultValue: "Failed to update extension repository"
                ),
                result: pullResult
            ))
        }
        return CmuxUseCheckoutResult(url: checkoutURL, action: "updated")
    }

    func resolveGitExecutable() throws -> String {
        if let gitPath = resolveExecutableInPath("git") {
            return gitPath
        }
        if FileManager.default.isExecutableFile(atPath: "/usr/bin/git") {
            return "/usr/bin/git"
        }
        throw CLIError(message: String(
            localized: "cli.use.error.gitRequired",
            defaultValue: "cmux use requires git in PATH"
        ))
    }

    func processFailureMessage(_ message: String, result: CLIProcessResult) -> String {
        String(
            localized: "cli.use.error.processFailedWithExit",
            defaultValue: "\(message) (exit \(result.status))"
        )
    }
}
