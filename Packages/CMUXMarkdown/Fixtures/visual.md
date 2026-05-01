# CMUX Markdown Visual Check

The renderer should handle **strong text**, *emphasis*, `inline code`, and [links](https://cmux.com/docs) without using MarkdownUI.

## Lists

- Bullet item one
- Bullet item with `code`
- Bullet item with **bold** and [a link](https://github.com/manaflow-ai/cmux)

1. Ordered item one
2. Ordered item two
3. Ordered item three

> Block quotes should have a subtle left rule and readable secondary text.
> Wrapped text should stay aligned inside the quote.

| Surface | Renderer | Status |
| --- | --- | --- |
| Markdown panel | CMUXMarkdownView | local package |
| Sidebar description | Attributed renderer | custom parser |
| Codex/session metadata | Attributed renderer | no Apple markdown parser |

```swift
struct MarkdownRenderer {
    let parser = "CMUXMarkdown"
    func render() -> String { "fast local markdown" }
}
```

---

Final paragraph after a thematic break.
