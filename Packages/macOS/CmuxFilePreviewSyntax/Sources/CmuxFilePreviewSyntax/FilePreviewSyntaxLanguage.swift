/// A source-language family recognized by the built-in file preview.
public enum FilePreviewSyntaxLanguage: CaseIterable, Equatable, Hashable, Sendable {
    /// Swift source.
    case swift
    /// C source and headers.
    case cFamily
    /// C++ source and headers.
    case cpp
    /// Objective-C and Objective-C++ source.
    case objc
    /// Java source.
    case java
    /// Kotlin source and scripts.
    case kotlin
    /// C# source.
    case csharp
    /// JavaScript source and modules.
    case javascript
    /// TypeScript source and modules.
    case typescript
    /// Python source and stubs.
    case python
    /// Ruby source and common Ruby build files.
    case ruby
    /// Go source.
    case go
    /// Rust source.
    case rust
    /// PHP source.
    case php
    /// Shell scripts and common shell configuration files.
    case shell
    /// SQL source.
    case sql
    /// CSS and common CSS preprocessors.
    case css
    /// JSON and JSON-with-comments documents.
    case json
    /// YAML documents.
    case yaml
    /// TOML documents.
    case toml
    /// INI-style configuration documents.
    case ini
}
