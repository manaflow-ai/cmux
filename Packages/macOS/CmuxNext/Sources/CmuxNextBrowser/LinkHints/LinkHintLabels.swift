import Foundation

/// Labels for link hints (Vimium's scheme): home-row letters first, every
/// label the same length or one shorter, and no label a prefix of another,
/// so typing a whole label always picks exactly one target.
public nonisolated enum LinkHintLabels {
    public static let alphabet = Array("sadfjklewcmpgh").map(String.init)

    /// `count` distinct labels, prefix-free, shortest first.
    public static func make(count: Int, alphabet: [String] = alphabet) -> [String] {
        guard count > 0, alphabet.count > 1 else { return [] }
        // Breadth-first: replace the shortest label with its children (a
        // letter in front) until there are enough leaves. The leaves are
        // suffix-free, so reversed they are prefix-free; sorting before the
        // reversal spreads labels that share a first letter across the page.
        var labels = [""]
        var offset = 0
        while labels.count - offset < count || labels.count == 1 {
            let parent = labels[offset]
            offset += 1
            labels += alphabet.map { $0 + parent }
        }
        return labels[offset..<offset + count].sorted().map { String($0.reversed()) }
    }
}
