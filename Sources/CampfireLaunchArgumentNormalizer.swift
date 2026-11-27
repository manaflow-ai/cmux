import Foundation

struct CampfireLaunchArgumentNormalizer: Sendable {
    var defaultExecutable: String

    func normalized(arguments: [String]) -> [String] {
        guard !arguments.isEmpty else { return [defaultExecutable] }
        if argumentLooksLikeExecutable(arguments[0]) {
            if arguments.count > 1, argumentLooksLikeBunfsEntry(arguments[1]) {
                return [arguments[0]] + Array(arguments.dropFirst(2))
            }
            return arguments
        }
        if argumentLooksLikeJavaScriptRuntime(arguments[0]),
           let scriptIndex = scriptArgumentIndex(in: arguments) {
            return [defaultExecutable] + Array(arguments.dropFirst(scriptIndex + 1))
        }
        return [defaultExecutable] + Array(arguments.dropFirst())
    }

    private func scriptArgumentIndex(in arguments: [String]) -> Int? {
        guard arguments.count > 1 else { return nil }
        return arguments.indices.dropFirst().first { argumentLooksLikeScript(arguments[$0]) }
    }

    private func argumentLooksLikeBunfsEntry(_ value: String) -> Bool {
        let normalized = value.replacingOccurrences(of: "\\", with: "/")
        return normalized.contains("$bunfs")
            || normalized.contains("~BUN")
            || normalized.contains("%7EBUN")
    }

    private func argumentLooksLikeExecutable(_ value: String) -> Bool {
        URL(fileURLWithPath: value).lastPathComponent.compare(
            "campfire",
            options: [.caseInsensitive, .literal]
        ) == .orderedSame && !argumentLooksLikeBunfsEntry(value)
    }

    private func argumentLooksLikeScript(_ value: String) -> Bool {
        let normalized = value.replacingOccurrences(of: "\\", with: "/").lowercased()
        let base = URL(fileURLWithPath: normalized).lastPathComponent
        return ["campfire.ts", "campfire.js", "campfire"].contains(base)
            && (normalized.contains("/campfire") || normalized.contains("packages/session"))
    }

    private func argumentLooksLikeJavaScriptRuntime(_ value: String) -> Bool {
        let base = URL(fileURLWithPath: value).lastPathComponent.lowercased()
        return ["node", "bun", "deno", "tsx", "ts-node"].contains(base)
    }
}
