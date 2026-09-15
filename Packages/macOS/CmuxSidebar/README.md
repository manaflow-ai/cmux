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

Tests can use an isolated temporary file through the same descriptor-backed path:

```swift
try fixturePNGData.write(to: temporaryImageURL)
let loader = SidebarStatusIconImageLoader(fileReader: SidebarStatusIconFileReader())
let image = await loader.image(at: temporaryImageURL.path)
```
