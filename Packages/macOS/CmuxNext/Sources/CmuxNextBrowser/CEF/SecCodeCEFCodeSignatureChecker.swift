import Foundation
import Security

/// Strictly checks every executable item in a downloaded runtime against the
/// Developer ID team embedded in the app's signed runtime pin.
struct SecCodeCEFCodeSignatureChecker: CEFCodeSignatureChecking {
    nonisolated func invalidItem(in layout: CEFRuntimeLayout, teamID: String) -> String? {
        guard !teamID.isEmpty,
              teamID.allSatisfy({ $0.isASCII && ($0.isUppercase || $0.isNumber) }) else {
            return "missing Developer ID team"
        }
        guard let entries = try? FileManager.default.contentsOfDirectory(atPath: layout.frameworksDirectory.path) else {
            return layout.frameworksDirectory.lastPathComponent
        }
        let helpers = entries
            .filter { $0.hasSuffix(".app") && $0.contains(" Helper") }
            .sorted()
            .map { layout.frameworksDirectory.appending(path: $0) }
        let items = [layout.frameworkDirectory, layout.shim] + helpers
        guard !helpers.isEmpty else { return layout.helperApp.lastPathComponent }
        return items.first(where: { !isValid($0, teamID: teamID) })?.lastPathComponent
    }

    private nonisolated func isValid(_ item: URL, teamID: String) -> Bool {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(item as CFURL, [], &code) == errSecSuccess, let code else { return false }
        var requirement: SecRequirement?
        let text = "anchor apple generic and certificate leaf[subject.OU] = \"\(teamID)\""
        guard SecRequirementCreateWithString(text as CFString, [], &requirement) == errSecSuccess,
              let requirement else { return false }
        let flags = SecCSFlags(rawValue: kSecCSCheckAllArchitectures | kSecCSStrictValidate | kSecCSCheckNestedCode)
        // concurrency-allow: CEFRuntime.loadLibrary runs it on the library-load thread (Task.detached); only the debug-window startBlocking path would run it on main, and that path has no caller
        return SecStaticCodeCheckValidity(code, flags, requirement) == errSecSuccess
    }
}
