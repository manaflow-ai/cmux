import Foundation

/// Resolves the machine reference a user typed after an id-taking `cmux vm` verb.
///
/// `cmux vm ls` prints a machine's display name, else its slug, else its id, while
/// the Cloud API looks machines up by provider id only. Every verb resolves the
/// typed reference against the listed machines with these rules.
public enum CloudVMReference {
    /// One listed machine, reduced to the fields a reference can match.
    public struct Candidate: Equatable, Sendable {
        /// Creates a candidate from a `vm.list` entry.
        public init(id: String, displayName: String?, slug: String?) {
            self.id = id
            self.displayName = displayName
            self.slug = slug
        }

        /// The provider id the Cloud API is keyed by.
        public let id: String
        /// The user-facing display name, when the machine has one.
        public let displayName: String?
        /// The generated slug, when the machine has one.
        public let slug: String?
    }

    /// The outcome of resolving a reference against the listed machines.
    public enum Resolution: Equatable, Sendable {
        /// The reference names exactly this machine id.
        case id(String)
        /// The reference is the label of more than one machine; these are their ids.
        case ambiguous([String])
        /// Nothing listed matches; the caller sends the reference as typed.
        case unmatched
    }

    /// An exact listed id wins; otherwise the single machine whose display name or
    /// slug equals the reference. Matching is exact and case-sensitive.
    public static func resolve(_ reference: String, in machines: [Candidate]) -> Resolution {
        guard !reference.isEmpty else { return .unmatched }
        if machines.contains(where: { $0.id == reference }) {
            return .id(reference)
        }
        var ids: [String] = []
        for machine in machines where machine.displayName == reference || machine.slug == reference {
            if !ids.contains(machine.id) { ids.append(machine.id) }
        }
        switch ids.count {
        case 0: return .unmatched
        case 1: return .id(ids[0])
        default: return .ambiguous(ids)
        }
    }

    /// Whether the reference has the shape of a provider machine id (`vm-` followed
    /// by 32 lowercase hex digits, or the bare 32 digits), so the CLI can skip
    /// listing machines before sending it.
    public static func looksLikeMachineID(_ reference: String) -> Bool {
        let digits = reference.hasPrefix("vm-") ? reference.dropFirst(3) : Substring(reference)
        return digits.count == 32 && digits.allSatisfy { ("0"..."9").contains($0) || ("a"..."f").contains($0) }
    }
}
