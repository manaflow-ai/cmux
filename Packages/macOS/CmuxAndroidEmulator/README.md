# CmuxAndroidEmulator

`CmuxAndroidEmulator` discovers a user-installed Android SDK, lists Android Virtual Devices through `emulator -list-avds`, reads running state through `adb`, and launches the vendor emulator window. It ships no Android executable, system image, or third-party dependency.

Production constructs `AndroidSDKLocator`, `CommandRunner`, and `AndroidEmulatorProcessLauncher` in the app composition root. Tests inject `AndroidSDKLocating`, `CommandRunning`, and `AndroidEmulatorProcessLaunching` fakes, so they never require an SDK or spawn a process.

```swift
let service = AndroidEmulatorService(
    sdkLocator: fakeLocator,
    commands: fakeCommands,
    processLauncher: fakeLauncher
)
let snapshot = try await service.snapshot()
```
