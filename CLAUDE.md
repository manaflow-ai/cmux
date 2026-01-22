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
  - `TerminalController.swift` - Unix socket server for programmatic control
- `tests/` - Test files and utilities
  - `ghosttytabs.py` - Python client library for socket API
  - `test_ctrl_socket.py` - Main automated test suite
- `GhosttyKit.xcframework/` - libghostty static library (gitignored, rebuild from /tmp/ghostty)
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

## Testing

### Unix Socket Control API

GhosttyTabs exposes a Unix socket at `/tmp/ghosttytabs.sock` for programmatic control and automated testing. The socket is created when the app launches.

#### Socket Commands

Text-based protocol with newline-delimited commands:

| Command | Description | Response |
|---------|-------------|----------|
| `ping` | Check if server is running | `PONG` |
| `list_tabs` | List all tabs | `* 0: <UUID> <title>` (per line) |
| `new_tab` | Create a new tab | `OK <UUID>` |
| `close_tab <id>` | Close tab by UUID | `OK` or `ERROR: ...` |
| `select_tab <id\|index>` | Select tab by UUID or index | `OK` or `ERROR: ...` |
| `current_tab` | Get current tab UUID | `<UUID>` |
| `send <text>` | Send text to terminal | `OK` |
| `send_key <key>` | Send special key | `OK` |
| `help` | Show available commands | Help text |

#### Special Keys for `send_key`

- `ctrl-c`, `ctrl-d`, `ctrl-z`, `ctrl-\` - Control signals
- `enter`, `tab`, `escape`, `backspace` - Common keys
- `ctrl-<letter>` - Any control+letter combination

#### Text Escaping for `send`

Use `\n` for Enter (carriage return), `\t` for tab, `\r` for raw CR.

### Python Client Library

Located at `tests/ghosttytabs.py`:

```python
from ghosttytabs import GhosttyTabs

with GhosttyTabs() as client:
    # Send text with Enter
    client.send("echo hello\n")

    # Send special keys
    client.send_ctrl_c()  # Interrupt
    client.send_ctrl_d()  # EOF
    client.send_key("enter")

    # Tab management
    tabs = client.list_tabs()
    client.new_tab()
    client.select_tab(0)
```

### Running Tests

```bash
# Build and launch the app first
pkill -9 GhosttyTabs 2>/dev/null
xcodebuild -scheme GhosttyTabs -configuration Release build
open ~/Library/Developer/Xcode/DerivedData/GhosttyTabs-cbjivvtpirygxbbgqlpdpiiyjnwh/Build/Products/Release/GhosttyTabs.app
sleep 3

# Run the main test suite (tests Ctrl+C, Ctrl+D)
python3 tests/test_ctrl_socket.py

# Interactive CLI for manual testing
python3 tests/ghosttytabs.py
```

### Writing New Tests

1. **Use marker files for verification** - Create temp files to verify commands executed:
   ```python
   marker = Path(tempfile.gettempdir()) / f"test_marker_{os.getpid()}"
   client.send(f"touch {marker}\n")
   time.sleep(0.5)
   assert marker.exists()
   ```

2. **Allow settling time** - Terminal commands need time to execute:
   ```python
   client.send("sleep 5\n")
   time.sleep(0.3)  # Wait for command to start
   client.send_ctrl_c()
   time.sleep(0.3)  # Wait for interrupt
   ```

3. **Clean up marker files** - Always remove test artifacts:
   ```python
   try:
       # test code
   finally:
       marker.unlink(missing_ok=True)
   ```

### Test Files

- `tests/ghosttytabs.py` - Python client library for socket API
- `tests/test_ctrl_socket.py` - Automated Ctrl+C/D test suite (main tests)
- `tests/test_signals_auto.py` - PTY-based signal tests (standalone)
- `tests/test_ctrl_interactive.py` - Interactive manual tests
- `tests/test_ctrl_signals.sh` - Simple bash signal test
- `tests/test_app_keystrokes.sh` - AppleScript keystroke tests (deprecated)
