/// One styled stretch of the status bar's line.
public struct StatusBarRun: Equatable, Sendable {
    /// Foreground color of a run.
    public enum Color: Equatable, Sendable {
        /// One of the 16 ANSI colors.
        case palette(Int)
        /// A 24-bit color from `38;2;r;g;b`.
        case rgb(UInt8, UInt8, UInt8)
    }

    /// The visible text, with every escape sequence removed.
    public var text: String
    /// Foreground color, or nil for the default.
    public var color: Color?
    /// Set by SGR 1.
    public var bold = false
    /// Set by SGR 2.
    public var dim = false
    /// Target of the OSC 8 hyperlink the run sits inside.
    public var link: String?

    /// Creates a run.
    public init(text: String, color: Color? = nil, bold: Bool = false, dim: Bool = false, link: String? = nil) {
        self.text = text
        self.color = color
        self.bold = bold
        self.dim = dim
        self.link = link
    }

    /// Splits one line of program output into runs. SGR colors, bold, dim and
    /// OSC 8 hyperlinks are kept; every other escape sequence is dropped.
    public static func parse(_ line: String) -> [StatusBarRun] {
        var runs: [StatusBarRun] = []
        var style = StatusBarRun(text: "")
        var text = String.UnicodeScalarView()

        func flush() {
            guard !text.isEmpty else { return }
            if var last = runs.last {
                last.text = ""
                if last == style {
                    runs[runs.count - 1].text += String(text)
                    text = String.UnicodeScalarView()
                    return
                }
            }
            var run = style
            run.text = String(text)
            runs.append(run)
            text = String.UnicodeScalarView()
        }

        let scalars = Array(line.unicodeScalars)
        var i = 0
        while i < scalars.count {
            guard scalars[i] == "\u{1b}" else {
                if scalars[i].value >= 0x20 { text.append(scalars[i]) }
                i += 1
                continue
            }
            let introducer = i + 1 < scalars.count ? scalars[i + 1] : nil
            i += 2
            if introducer == "[" {
                let start = i
                while i < scalars.count, !(0x40...0x7e).contains(scalars[i].value) { i += 1 }
                guard i < scalars.count else { break }
                if scalars[i] == "m" {
                    flush()
                    applySGR(String(String.UnicodeScalarView(scalars[start..<i])), to: &style)
                }
                i += 1
            } else if introducer == "]" {
                let start = i
                while i < scalars.count, scalars[i] != "\u{07}", scalars[i] != "\u{1b}" { i += 1 }
                let body = String(String.UnicodeScalarView(scalars[start..<i]))
                // Terminated by BEL or by ESC \.
                if i < scalars.count { i += scalars[i] == "\u{07}" ? 1 : 2 }
                if body.hasPrefix("8;") {
                    flush()
                    // 8;params;URI, where an empty URI closes the link.
                    let uri = body.split(separator: ";", maxSplits: 2, omittingEmptySubsequences: false)
                        .dropFirst(2).first.map(String.init) ?? ""
                    style.link = uri.isEmpty ? nil : uri
                }
            }
        }
        flush()
        return runs
    }

    private static func applySGR(_ parameters: String, to style: inout StatusBarRun) {
        let codes = parameters.isEmpty
            ? [0]
            : parameters.split(separator: ";", omittingEmptySubsequences: false).map { Int($0) ?? 0 }
        var i = 0
        while i < codes.count {
            switch codes[i] {
            case 0:
                // A reset ends colors and weight, not the hyperlink.
                style = StatusBarRun(text: "", link: style.link)
            case 1: style.bold = true
            case 2: style.dim = true
            case 22: style.bold = false; style.dim = false
            case 30...37: style.color = .palette(codes[i] - 30)
            case 39: style.color = nil
            case 90...97: style.color = .palette(codes[i] - 90 + 8)
            case 38, 48:
                // Extended colors; backgrounds are parsed only so their arguments are skipped.
                if i + 4 < codes.count, codes[i + 1] == 2 {
                    if codes[i] == 38 {
                        style.color = .rgb(
                            UInt8(clamping: codes[i + 2]),
                            UInt8(clamping: codes[i + 3]),
                            UInt8(clamping: codes[i + 4])
                        )
                    }
                    i += 4
                } else if i + 2 < codes.count, codes[i + 1] == 5 {
                    if codes[i] == 38, codes[i + 2] < 16 { style.color = .palette(codes[i + 2]) }
                    i += 2
                }
            default: break
            }
            i += 1
        }
    }
}

/// Consecutive runs that share a link target, so each link is one click target.
public struct StatusBarSegment: Equatable, Sendable {
    /// The OSC 8 target shared by every run here, or nil for plain text.
    public var link: String?
    /// The runs, in order.
    public var runs: [StatusBarRun]

    /// Creates a segment.
    public init(link: String?, runs: [StatusBarRun]) {
        self.link = link
        self.runs = runs
    }

    /// Groups `runs` into segments, merging neighbors with the same link.
    public static func segments(of runs: [StatusBarRun]) -> [StatusBarSegment] {
        var segments: [StatusBarSegment] = []
        for run in runs {
            if let last = segments.last, last.link == run.link {
                segments[segments.count - 1].runs.append(run)
            } else {
                segments.append(StatusBarSegment(link: run.link, runs: [run]))
            }
        }
        return segments
    }
}
