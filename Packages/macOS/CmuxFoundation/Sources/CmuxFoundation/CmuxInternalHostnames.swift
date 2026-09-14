import Foundation

/// The `<name>.internal` hostname cmux offers for a Cloud VM's private
/// address, and the `/etc/hosts` management that makes the name resolve.
///
/// The name only works from a Mac whose WireGuard tunnel is up (the address
/// it resolves to is unroutable otherwise) AND whose `/etc/hosts` has been
/// synced (`cmux vpn hosts`), so nothing in the app builds a clickable link
/// out of it — `directPortURL` uses the raw address instead, unconditionally.
/// The `.internal` name is a manual-use convenience (typed into a terminal,
/// an SSH config) that this module still builds and publishes to
/// `/etc/hosts`; it is just never the thing a click depends on.
///
/// Shared between the app (which builds the link a person clicks) and the CLI
/// (`cmux vpn hosts`, which owns writing `/etc/hosts`) so the slug algorithm
/// producing the name can never drift between the two.
public enum CmuxInternalHostnames {
    /// Markers bounding cmux's block in `/etc/hosts`. Anything outside them
    /// (the user's own entries, other tools') is preserved byte-for-byte.
    public static let blockBeginMarker = "# BEGIN cmux managed hosts (cmux vpn hosts)"
    public static let blockEndMarker = "# END cmux managed hosts"

    /// The default tunnel scope (production): its block keeps the historical
    /// unscoped markers. Any other scope — a dev build on the same Mac, whose
    /// machines live on another private network behind its own tunnel — gets
    /// markers carrying the scope name, so each build owns exactly one block
    /// and never rewrites or clears the other's.
    public static let defaultScope = "cmux"

    public static func blockBeginMarker(scope: String?) -> String {
        guard let scope = scopedName(scope) else { return blockBeginMarker }
        return "# BEGIN cmux managed hosts [\(scope)] (cmux vpn hosts)"
    }

    public static func blockEndMarker(scope: String?) -> String {
        guard let scope = scopedName(scope) else { return blockEndMarker }
        return "# END cmux managed hosts [\(scope)]"
    }

    private static func scopedName(_ scope: String?) -> String? {
        guard let scope = scope?.trimmingCharacters(in: .whitespacesAndNewlines), !scope.isEmpty, scope != defaultScope else {
            return nil
        }
        return scope
    }

    /// One machine's entry: the private address and every name it should
    /// answer to (its id always; its display label too, when it has one and
    /// the label survives slugging).
    public struct Entry: Equatable, Sendable {
        public let address: String
        public let hostnames: [String]

        public init(address: String, hostnames: [String]) {
            self.address = address
            self.hostnames = hostnames
        }
    }

    /// The hostname this app would offer for a machine, given its stable id
    /// and (optional) display label — the label when it slugs to something
    /// non-empty, else the id. Both end in `.internal`.
    public static func hostname(id: String, label: String?) -> String {
        if let label, let slug = slug(label), !slug.isEmpty {
            return "\(slug).internal"
        }
        return "\(slugOrRaw(id)).internal"
    }

    /// Lowercase alphanumeric-and-hyphen, collapsing runs and trimming edges —
    /// a valid DNS label, or nil when nothing usable survives (emoji-only
    /// labels, etc.), so the caller falls back to the id.
    public static func slug(_ raw: String) -> String? {
        let lowered = raw.lowercased()
        var out = ""
        var lastWasHyphen = false
        for scalar in lowered.unicodeScalars {
            if CharacterSet.alphanumerics.contains(scalar) {
                out.unicodeScalars.append(scalar)
                lastWasHyphen = false
            } else if !lastWasHyphen, !out.isEmpty {
                out.append("-")
                lastWasHyphen = true
            }
        }
        while out.hasSuffix("-") { out.removeLast() }
        return out.isEmpty ? nil : out
    }

    private static func slugOrRaw(_ raw: String) -> String {
        slug(raw) ?? raw
    }

    /// The URL a click on a machine's port row actually navigates to: straight
    /// to its private-network address, over the WireGuard tunnel — never
    /// through a provider port-forwarding proxy, which Freestyle's public
    /// platform does not offer for arbitrary ports. Deliberately the raw
    /// address, not the `.internal` name `cmux vpn hosts` publishes: that name
    /// only resolves once `/etc/hosts` has been synced, and a link that only
    /// sometimes works is worse than one that always does. An IPv6 literal is
    /// bracketed the way every URL scheme requires.
    public static func directPortURL(privateAddress: String, port: Int) -> String {
        let bracketed = privateAddress.contains(":") ? "[\(privateAddress)]" : privateAddress
        return "http://\(bracketed):\(port)"
    }

    /// Render entries as the managed block's body (no markers): one `ip host`
    /// line per hostname, sorted for a stable, diffable file.
    public static func renderBlockBody(_ entries: [Entry]) -> String {
        var lines: [String] = []
        for entry in entries {
            for host in entry.hostnames {
                lines.append("\(entry.address) \(host)")
            }
        }
        return lines.sorted().joined(separator: "\n")
    }

    /// Splice the managed block into an existing `/etc/hosts` body: replaces a
    /// prior cmux block wherever it is, or appends a fresh one (with a
    /// separating blank line when the file is non-empty and doesn't already
    /// end in one). `body` may be empty, which removes the block entirely
    /// (leaving one trailing newline) — used when this Mac has no machines
    /// left to publish.
    public static func mergedHostsFile(current: String, body: String, scope: String? = nil) -> String {
        let beginMarker = blockBeginMarker(scope: scope)
        let endMarker = blockEndMarker(scope: scope)
        let block = body.isEmpty ? "" : "\(beginMarker)\n\(body)\n\(endMarker)"
        let lines = current.components(separatedBy: "\n")
        guard let beginIndex = lines.firstIndex(of: beginMarker) else {
            guard !block.isEmpty else { return current }
            let trimmed = current.hasSuffix("\n") || current.isEmpty ? current : current + "\n"
            let separator = trimmed.isEmpty ? "" : "\n"
            return trimmed + separator + block + "\n"
        }
        let endIndex = lines[beginIndex...].firstIndex(of: endMarker) ?? (lines.count - 1)
        var out = Array(lines[..<beginIndex])
        // Drop a blank line this block owns immediately before it, so removing
        // an only block doesn't leave the file growing a blank line each sync.
        if block.isEmpty, out.last == "" { out.removeLast() }
        if !block.isEmpty { out.append(contentsOf: block.components(separatedBy: "\n")) }
        out.append(contentsOf: lines[(endIndex + 1)...])
        return out.joined(separator: "\n")
    }
}
