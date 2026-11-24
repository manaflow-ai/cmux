// Xcode target `cmux-next`: all app code lives in Packages/macOS/CmuxNext.
//
// Contents/MacOS/cmux is this stub; the code is Contents/Frameworks/CmuxNextApp.framework
// (Packages/macOS/CmuxNext/Package.swift, CMUX-629). Chromium's code-sign clone hard-links
// the main executable on every launch, and XProtect then scans that file again before the
// next launch: a stub costs milliseconds, the 100 MB executable cost about 500 ms.
// The framework exports only `cmux_next_app_main` (CmuxNextApp.swift); a live code
// build links CmuxNextApp statically and still exports it.
@_silgen_name("cmux_next_app_main")
func cmuxNextAppMain()

cmuxNextAppMain()
