import CmuxNextCompat
import Foundation
import Security

/// Strictly checks every executable item in a downloaded runtime against the
/// Developer ID team embedded in the app's signed runtime pin. Each item's
/// answer is kept per version of it (``StaticCodeValidityCache``): the
/// installer checked the same items before this load.
struct SecCodeCEFCodeSignatureChecker: CEFCodeSignatureChecking {
    nonisolated func invalidItem(in layout: CEFRuntimeLayout, teamID: String) -> String? {
        guard !teamID.isEmpty,
              teamID.allSatisfy({ $0.isASCII && ($0.isUppercase || $0.isNumber) }) else {
            return "missing Developer ID team"
        }
        guard let entries = try? FileManager.checked.contentsOfDirectory(atPath: layout.frameworksDirectory.path) else {
            return layout.frameworksDirectory.lastPathComponent
        }
        let helpers = entries
            .filter { $0.hasSuffix(".app") && $0.contains(" Helper") }
            .sorted()
            .map { layout.frameworksDirectory.appending(path: $0) }
        let items = [layout.frameworkDirectory, layout.shim] + helpers
        guard !helpers.isEmpty else { return layout.helperApp.lastPathComponent }
        let requirement = "anchor apple generic and certificate leaf[subject.OU] = \"\(teamID)\""
        let flags = SecCSFlags(rawValue: kSecCSCheckAllArchitectures | kSecCSStrictValidate | kSecCSCheckNestedCode)
        return items.first(where: { !StaticCodeValidityCache.process.isValid($0, flags: flags, requirement: requirement) })?.lastPathComponent
    }
}
