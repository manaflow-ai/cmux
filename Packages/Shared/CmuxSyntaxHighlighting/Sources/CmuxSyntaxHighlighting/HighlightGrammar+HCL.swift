extension HighlightGrammar {
    /// HashiCorp Configuration Language: Terraform, OpenTofu, Packer, Nomad
    /// and other HCL files.
    ///
    /// Scopes stay single-word (`title`, not `title.function.invoke`) because
    /// Highlightr looks up a span's whole class string in the theme, so a
    /// compound highlight.js 11 scope renders uncolored. Function calls use
    /// `title` rather than `built_in`: Highlightr's CSS parser files the
    /// bundled themes' `built_in` and `type` rules under `.hljs-class
    /// .hljs-title`, so those scopes never get a color.
    static let hcl = HighlightGrammar(
        name: "hcl",
        definitionScript: #"""
        (function (hljs) {
          const IDENTIFIER = /[A-Za-z_][A-Za-z0-9_-]*/;
          const KEYWORDS = {
            $pattern: IDENTIFIER,
            keyword: ['for', 'in', 'if', 'else', 'endif', 'endfor'],
            literal: ['true', 'false', 'null']
          };
          const NUMBER = {
            scope: 'number',
            match: /\b\d+(?:\.\d+)?(?:[eE][+-]?\d+)?\b/,
            relevance: 0
          };
          const FUNCTION_CALL = {
            scope: 'title',
            match: /[A-Za-z_][A-Za-z0-9_]*(?=\()/
          };
          const REFERENCE = {
            scope: 'variable',
            match: /\b(?:var|local|module|data|each|count|path|self|terraform)(?=\.)/
          };
          const ESCAPED_TEMPLATE = { match: /\$\$\{|%%\{/ };
          const INTERPOLATION = {
            scope: 'subst',
            begin: /[$%]\{~?/,
            end: /~?\}/,
            keywords: KEYWORDS,
            contains: []
          };
          const STRING = {
            scope: 'string',
            begin: /"/,
            end: /"/,
            contains: [hljs.BACKSLASH_ESCAPE, ESCAPED_TEMPLATE, INTERPOLATION]
          };
          const HEREDOC = hljs.END_SAME_AS_BEGIN({
            scope: 'string',
            begin: /<<-?[ \t]*([A-Za-z_][A-Za-z0-9_]*)[ \t]*$/,
            end: /^[ \t]*([A-Za-z_][A-Za-z0-9_]*)[ \t]*$/,
            contains: [ESCAPED_TEMPLATE, INTERPOLATION]
          });
          const NESTED_BRACES = {
            begin: /\{/,
            end: /\}/,
            keywords: KEYWORDS,
            contains: ['self', STRING, NUMBER, FUNCTION_CALL, REFERENCE]
          };
          INTERPOLATION.contains = [STRING, NUMBER, FUNCTION_CALL, REFERENCE, NESTED_BRACES];
          // `resource "type" "name" {`, `locals {`, `dynamic "rule" {`.
          const BLOCK_TYPE = {
            scope: 'keyword',
            match: /[A-Za-z_][A-Za-z0-9_-]*(?=(?:[ \t]+(?:"[^"\n]*"|[A-Za-z_][A-Za-z0-9_-]*))*[ \t]*\{)/
          };
          // `name = ...`, but not `==` or the `=>` of a for expression.
          const ATTRIBUTE = {
            scope: 'attr',
            match: /[A-Za-z_][A-Za-z0-9_-]*(?=[ \t]*=(?![=>]))/
          };
          return {
            name: 'HCL',
            aliases: ['terraform', 'tf', 'tofu'],
            keywords: KEYWORDS,
            contains: [
              hljs.HASH_COMMENT_MODE,
              hljs.C_LINE_COMMENT_MODE,
              hljs.C_BLOCK_COMMENT_MODE,
              HEREDOC,
              STRING,
              NUMBER,
              BLOCK_TYPE,
              ATTRIBUTE,
              FUNCTION_CALL,
              REFERENCE
            ]
          };
        })
        """#
    )
}
