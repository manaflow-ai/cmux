# Markdown Code Block Visual Fixture

A useful rule of thumb:

```swift
@MainActor
final class ThingTheViewTalksTo { ... } // usually good

actor ThingThatOwnsSharedBackgroundState { ... } // often better

struct PureModelOrDTO { ... } // usually no actor

final class APIClient { ... } // usually not MainActor
```

For async workflows, keep expensive work off the main actor and return to it only for UI state:

```swift
func refresh() async {
    isLoading = true

    let items = await repository.loadItems() // repository should not be MainActor

    self.items = items
    isLoading = false
}
```
