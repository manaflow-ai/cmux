import CMUXMarkdown
import Foundation

let sample = """
# CMUX Markdown Benchmark

This document exercises **strong**, *emphasis*, `inline code`, [links](https://cmux.com/docs),
soft line breaks, lists, tables, block quotes, and fenced code.

## Lists

- First item with `code`
- Second item with [a link](https://github.com/manaflow-ai/cmux)
- Third item with **bold text**

1. Ordered one
2. Ordered two
3. Ordered three

> Block quotes can contain **inline markup** and links to [docs](https://cmux.com/docs).

| Surface | State | Notes |
| --- | --- | --- |
| terminal | synced | scrollback replay |
| markdown | local | custom renderer |
| codex | indexed | fast sidebar |

```swift
struct Example {
    let value: Int
    func render() -> String { "value=\\(value)" }
}
```
"""

let document = Array(repeating: sample, count: 160).joined(separator: "\n\n")
let iterations = 250

@inline(never)
func consume(_ value: Int) {
    if value == Int.min {
        print(value)
    }
}

func measure(_ name: String, iterations: Int, body: () -> Int) {
    let start = DispatchTime.now().uptimeNanoseconds
    var total = 0
    for _ in 0..<iterations {
        total &+= body()
    }
    let end = DispatchTime.now().uptimeNanoseconds
    consume(total)

    let seconds = Double(end - start) / 1_000_000_000.0
    let megabytes = Double(document.utf8.count * iterations) / 1_048_576.0
    let throughput = megabytes / seconds
    print("\(name): \(String(format: "%.2f", throughput)) MiB/s, \(iterations) iterations, checksum \(total)")
}

print("CMUXMarkdown benchmark")
print("bytes: \(document.utf8.count)")
print("iterations: \(iterations)")

measure("parse", iterations: iterations) {
    CMUXMarkdown.parse(document).blocks.count
}

measure("parse+plain", iterations: iterations) {
    let parsed = CMUXMarkdown.parse(document)
    return CMUXMarkdown.plainText(from: parsed).utf8.count
}

measure("inline-attributed", iterations: iterations) {
    CMUXMarkdown.attributedString(fromMarkdown: document).characters.count
}
