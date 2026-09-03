# CmuxSidebar

`CmuxSidebar` owns the value models and service seams shared by cmux sidebar renderers.

## Local status images

Construct the image loader at the app composition root and inject it through
`SidebarStatusIconImageLoading`:

```swift
let loader = SidebarStatusIconImageLoader(
    fileReader: SidebarStatusIconFileReader()
)
let image = await loader.image(at: "/tmp/agent.png")
```

Tests can avoid ambient filesystem access by injecting bounded image data:

```swift
let loader = SidebarStatusIconImageLoader { _, _ in fixturePNGData }
```
