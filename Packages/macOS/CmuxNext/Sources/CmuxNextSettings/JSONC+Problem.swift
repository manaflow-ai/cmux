import Foundation

extension JSONC {
    /// A file's read or parse failure as a person reads it: where in the file and what, such as
    /// "unexpected character 'x' at line 5, column 3". Never the error's dump: the toast and the
    /// Settings row showed "Error Domain=NSCocoaErrorDomain Code=3840 … UserInfo={…}" (Leo,
    /// 2026-11-20: "bad toast of unreadable json").
    public static func problem(_ error: any Error, in source: String?) -> String {
        let ns = error as NSError
        let unreadable = error is Failure
            || (ns.domain == NSCocoaErrorDomain && ns.code == CocoaError.propertyListReadCorrupt.rawValue)
        if unreadable, let source,
           let problem = CmuxSettingsFFI.call("jsonc.strip", ["source": source])?["problem"] as? String {
            return problem // cmux-config `app_ops::jsonc::problem`
        }
        return unreadable ? "the text is not valid JSON" : sentence(ns.localizedDescription)
    }

    /// One clause to sit inside "could not be read (…)": first letter lowercased, "around" as
    /// "at", no closing period.
    private static func sentence(_ text: String) -> String {
        var out = text.trimmingCharacters(in: .whitespacesAndNewlines)
        while out.hasSuffix(".") { out.removeLast() }
        out = out.replacingOccurrences(of: " around line ", with: " at line ")
        guard let first = out.first, first.isUppercase, !(out.dropFirst().first?.isUppercase ?? false) else { return out }
        return first.lowercased() + out.dropFirst()
    }
}
