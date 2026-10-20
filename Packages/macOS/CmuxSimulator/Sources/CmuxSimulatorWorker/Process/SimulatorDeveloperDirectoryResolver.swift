import Foundation

struct SimulatorDeveloperDirectoryResolver: Sendable {
    typealias Lookup = @Sendable () -> String?

    private let lookup: Lookup
    private let fallback: String

    init(
        fallback: String = "/Applications/Xcode.app/Contents/Developer",
        lookup: @escaping Lookup = lookupSelectedDeveloperDirectory
    ) {
        self.lookup = lookup
        self.fallback = fallback
    }

    func resolve(environment: [String: String]) -> String {
        if let configured = environment["DEVELOPER_DIR"], !configured.isEmpty {
            return configured
        }
        return lookup() ?? fallback
    }
}

private func lookupSelectedDeveloperDirectory() -> String? {
    let output = Pipe()
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/xcode-select")
    process.arguments = ["-p"]
    process.standardOutput = output
    process.standardError = FileHandle.nullDevice
    do {
        try process.run()
        process.waitUntilExit()
    } catch {
        return nil
    }
    guard process.terminationStatus == 0 else { return nil }
    let value = String(
        data: output.fileHandleForReading.readDataToEndOfFile(),
        encoding: .utf8
    )?.trimmingCharacters(in: .whitespacesAndNewlines)
    return value?.isEmpty == false ? value : nil
}
