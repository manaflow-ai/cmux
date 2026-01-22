# GhosttyTabs

A macOS terminal app with vertical tabs, using libghostty (GhosttyKit.xcframework) for terminal emulation.

## User Preferences

- **Always use Release builds** when building and launching for testing
- Build libghostty with `-Doptimize=ReleaseFast` for performance

## Development

### Build and launch (Release)
```bash
cd /Users/lawrencechen/fun/cmux-terminal/GhosttyTabs
pkill -9 GhosttyTabs 2>/dev/null
xcodebuild -scheme GhosttyTabs -configuration Release build
open ~/Library/Developer/Xcode/DerivedData/GhosttyTabs-cbjivvtpirygxbbgqlpdpiiyjnwh/Build/Products/Release/GhosttyTabs.app
```

### Rebuild libghostty (optimized)
```bash
cd /tmp/ghostty
zig build -Demit-xcframework=true -Dxcframework-target=native -Doptimize=ReleaseFast
cp -R /tmp/ghostty/macos/GhosttyKit.xcframework /Users/lawrencechen/fun/cmux-terminal/GhosttyTabs/
```

### Project structure
- `Sources/` - Swift source files
  - `GhosttyTabsApp.swift` - App entry point with keyboard shortcuts
  - `ContentView.swift` - Main UI with vertical tabs sidebar
  - `TabManager.swift` - Tab state management
  - `GhosttyTerminalView.swift` - libghostty terminal integration
  - `GhosttyConfig.swift` - Ghostty config parser
- `GhosttyKit.xcframework/` - libghostty static library
- `ghostty.h` - Ghostty C API header
- `GhosttyTabs-Bridging-Header.h` - Swift bridging header

### Keyboard Shortcuts
- `Cmd+T` / `Cmd+N` / `Ctrl+Shift+`` - New tab
- `Cmd+W` - Close tab
- `Cmd+Shift+]` / `Ctrl+Tab` - Next tab
- `Cmd+Shift+[` / `Ctrl+Shift+Tab` - Previous tab
- `Cmd+1-9` - Jump to tab by number

### Config
Reads user's Ghostty config from:
`~/Library/Application Support/com.mitchellh.ghostty/config`
