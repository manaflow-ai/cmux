# cmux Desktop Prototype

Standalone Xcode prototype for a host-window desktop pane.

```bash
Prototypes/CMUXDesktopPrototype/script/run.sh
```

The app lists normal on-screen host windows, streams live video for the selected window when Screen Recording is allowed, and uses Accessibility to raise, arrange, click, scroll, and type into windows.

The main prototype shows a cmux-like split workspace. The selected app window can be synced into the right pane, which moves and resizes the real native window over that pane while keeping a live video backing underneath it.

Open `CMUXDesktopPrototype.xcworkspace` in Xcode for manual iteration.
