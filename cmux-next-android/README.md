# cmux-next-android

Native Android app for cmux-next (Kotlin, Jetpack Compose), the Android twin of `cmux-next-ios/`.

Milestone 1 (this): shell on mock data: onboarding and sign-in, tabs Home (Chief), Workspaces, Feed, Settings, true-black design tokens mirroring `CmuxMobileDesign`.

Next: Stack Auth sign-in, `cmux-mobile-api` presence, the Mac link through `cmux-mobile-link-ffi` (uniffi Kotlin bindings), terminal.

Build: `./gradlew assembleDebug` (JDK 17, Android SDK 35). Open a screen directly: `adb shell am start -n dev.cmux.android/.MainActivity --es screen workspaces`.
