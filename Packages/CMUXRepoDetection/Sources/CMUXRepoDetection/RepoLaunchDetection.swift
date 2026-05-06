import Foundation

public struct CMUXDetectedLaunchCommand: Equatable {
    public let command: String
    public let source: String

    public init(command: String, source: String) {
        self.command = command
        self.source = source
    }
}

public enum CMUXRepoDetection {
    public static func packageJSONLaunchCommand(in checkoutURL: URL) -> CMUXDetectedLaunchCommand? {
        guard let package = packageJSON(in: checkoutURL),
              let scripts = package["scripts"] as? [String: Any] else {
            return nil
        }

        for script in ["use", "cmux", "start", "dev"] {
            guard scripts[script] is String else { continue }
            return CMUXDetectedLaunchCommand(
                command: "\(packageManagerCommand(in: checkoutURL)) run \(script)",
                source: "package.json:scripts.\(script)"
            )
        }
        return nil
    }

    public static func packageJSON(in checkoutURL: URL) -> [String: Any]? {
        let packageURL = checkoutURL.appendingPathComponent("package.json", isDirectory: false)
        guard let data = try? Data(contentsOf: packageURL),
              let package = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return package
    }

    public static func packageManagerCommand(in checkoutURL: URL) -> String {
        let fm = FileManager.default
        if fm.fileExists(atPath: checkoutURL.appendingPathComponent("bun.lockb").path)
            || fm.fileExists(atPath: checkoutURL.appendingPathComponent("bun.lock").path) {
            return "bun"
        }
        if fm.fileExists(atPath: checkoutURL.appendingPathComponent("pnpm-lock.yaml").path) {
            return "pnpm"
        }
        if fm.fileExists(atPath: checkoutURL.appendingPathComponent("yarn.lock").path) {
            return "yarn"
        }
        return "npm"
    }

    public static func makefileLaunchCommand(in checkoutURL: URL) -> CMUXDetectedLaunchCommand? {
        for filename in ["Makefile", "makefile"] {
            let makefileURL = checkoutURL.appendingPathComponent(filename, isDirectory: false)
            guard let contents = try? String(contentsOf: makefileURL, encoding: .utf8) else { continue }
            for target in ["start", "run", "use"] where makefile(contents, hasTarget: target) {
                return CMUXDetectedLaunchCommand(command: "make \(target)", source: "\(filename):\(target)")
            }
        }
        return nil
    }

    public static func makefile(_ contents: String, hasTarget target: String) -> Bool {
        contents.split(separator: "\n", omittingEmptySubsequences: false).contains { rawLine in
            let line = String(rawLine)
            guard !line.hasPrefix("\t"), !line.trimmingCharacters(in: .whitespaces).hasPrefix("#") else {
                return false
            }
            return line.range(of: #"^\#(target):(\s|$)"#, options: .regularExpression) != nil
        }
    }
}
