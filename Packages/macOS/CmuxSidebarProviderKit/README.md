# CmuxSidebarProviderKit

Internal app-side kit for cmux-owned sidebar providers.

Use this package for in-process sidebar render models, sidebar provider descriptors, and provider mutations that run inside the cmux app. It is not the public extension SDK for third-party sidebar app extensions, and all types use `CmuxSidebarProvider` naming to keep that boundary visible.

External extension authors should import `CmuxExtensionKit` instead.
