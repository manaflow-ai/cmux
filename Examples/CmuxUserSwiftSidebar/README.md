# cmux Swift Sidebar File

Right-click the sidebar icon in cmux and choose **Load Swift Sidebar...**.
Select `CompactUnreadSidebar.swift`.

cmux builds only a small SwiftPM wrapper for the selected file. The app itself
is not rebuilt. The file can import `CmuxExtensionKit` and should end by calling:

```swift
try CmuxExtensionSidebarExecutable.run(provider: MyProvider())
```

The executable receives `CmuxExtensionSidebarSnapshot` JSON on stdin and returns
`CmuxExtensionSidebarRenderModel` JSON on stdout through `CmuxExtensionKit`.

Optional compile check:

```bash
swift build --package-path Examples/CmuxUserSwiftSidebar
```
