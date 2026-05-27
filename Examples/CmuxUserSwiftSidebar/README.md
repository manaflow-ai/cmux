# cmux Custom Sidebar

Right-click the sidebar icon in cmux and choose **Load Custom Sidebar**.
Select `CompactUnreadSidebar.swift`.

cmux builds only a small SwiftPM wrapper for the selected file. The app itself
is not rebuilt. The file can import `CmuxExtensionKit` and should end by calling:

```swift
try CmuxExtensionSidebarExecutable.run(provider: MyProvider())
```

The executable receives `CmuxExtensionSidebarSnapshot` JSON on stdin and returns
`CmuxExtensionSidebarRenderModel` JSON on stdout through `CmuxExtensionKit`.

You can also load it from the CLI:

```bash
cmux sidebar load Examples/CmuxUserSwiftSidebar/CompactUnreadSidebar.swift
```

cmux imports loaded sources into `~/.config/cmux/sidebars/`, next to the global
`~/.config/cmux/cmux.json` config file. You can also place sidebars directly in
that folder and run:

```bash
cmux sidebar sync
```

A folder can contain multiple `.swift` files when it includes either
`main.swift` or an `@main` entry point.

Optional compile check:

```bash
swift build --package-path Examples/CmuxUserSwiftSidebar
```
