import Foundation

/// The keys of one hint-mode session (Vimium's scheme, as in cmux-next's
/// link hints): letters narrow the labels until one is typed in full; a
/// letter no label continues with is ignored; Backspace undoes a letter.
struct WindowHintKeys: Equatable {
    enum Outcome: Equatable {
        /// Show only labels that start with `prefix`.
        case narrow(prefix: String)
        /// The label at this index is complete: act on its target.
        case pick(Int)
    }

    /// Home-row letters first.
    static let alphabet = Array("sadfjklewcmpgh").map(String.init)

    let labels: [String]
    private(set) var typed = ""

    init(count: Int) {
        labels = Self.labels(count: count)
    }

    /// A letter (lowercase), or nil for Backspace.
    mutating func type(_ letter: String?) -> Outcome {
        if let letter {
            let next = typed + letter.lowercased()
            if labels.contains(where: { $0.hasPrefix(next) }) { typed = next }
        } else if !typed.isEmpty {
            typed.removeLast()
        }
        if let index = labels.firstIndex(of: typed) { return .pick(index) }
        return .narrow(prefix: typed)
    }

    /// `count` distinct labels, prefix-free, shortest first, so typing a
    /// whole label always picks exactly one target.
    static func labels(count: Int, alphabet: [String] = alphabet) -> [String] {
        guard count > 0, alphabet.count > 1 else { return [] }
        // Breadth-first: replace the shortest label with its children (a
        // letter in front) until there are enough leaves. The leaves are
        // suffix-free, so reversed they are prefix-free; sorting before the
        // reversal spreads labels that share a first letter across the window.
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
