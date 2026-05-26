# Markdown Table Visual Fixture

This paragraph verifies **strong text**, *emphasis*, `inline code`, ~~strike~~, and [links](https://example.com).

Filenames should stay literal: shell/platformdelegate_mac.mm and AtlasLocalDemoPage.swift.

| Surface | Result | Notes |
| :--- | :---: | ---: |
| Local app | **pass** | 1200x746 |
| Remote host | pass | `cmux-macmini` |
| Escaped \| pipe | pass | [link](https://example.com) |

- Lists should keep compact indentation.
  - [AppDelegate.swift](file:///tmp/AppDelegate.swift) should not color the marker.
  - Nested list items should not drift.
1. [BrowserPanelView.swift](file:///tmp/BrowserPanelView.swift) should keep the number plain.
2. Ordered items should remain readable.

```swift
@MainActor
final class ThingTheViewTalksTo { } // usually good

actor ThingThatOwnsSharedBackgroundState { } // often better

struct PureModelOrDTO { } // usually no actor

func refresh() async {
    let items = await repository.loadItems() // repository should not be MainActor
    self.items = items
}
```
