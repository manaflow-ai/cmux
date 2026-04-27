// editor-bridge.js — cmux Editor ↔ Monaco bridge
// Exposes window.cmuxEditor for Swift to call, posts messages via
// window.webkit.messageHandlers.cmuxEditor for Monaco → Swift events.

(function () {
  "use strict";

  var editor = null;
  var diffEditor = null;
  var isDiffMode = false;
  var currentLanguage = "plaintext";
  var currentFilePath = "";

  // Post message to Swift.
  function postToNative(msg) {
    if (
      window.webkit &&
      window.webkit.messageHandlers &&
      window.webkit.messageHandlers.cmuxEditor
    ) {
      window.webkit.messageHandlers.cmuxEditor.postMessage(msg);
    }
  }

  // Detect dark mode from prefers-color-scheme or Swift override.
  function detectTheme() {
    return window.matchMedia &&
      window.matchMedia("(prefers-color-scheme: dark)").matches
      ? "vs-dark"
      : "vs";
  }

  // Initialize Monaco.
  function initMonaco() {
    require.config({
      paths: { vs: "vs" },
    });

    require(["vs/editor/editor.main"], function () {
      var container = document.getElementById("editor-container");
      container.innerHTML = "";

      editor = monaco.editor.create(container, {
        value: "",
        language: "plaintext",
        theme: detectTheme(),
        readOnly: true,
        automaticLayout: true,
        minimap: { enabled: true },
        scrollBeyondLastLine: false,
        fontSize: 12,
        fontFamily: '"SF Mono", Menlo, Monaco, "Courier New", monospace',
        lineNumbers: "on",
        renderWhitespace: "none",
        wordWrap: "off",
        folding: true,
        glyphMargin: false,
        largeFileOptimizations: true,
        maxTokenizationLineLength: 20000,
        scrollbar: {
          verticalScrollbarSize: 10,
          horizontalScrollbarSize: 10,
        },
        overviewRulerLanes: 0,
        hideCursorInOverviewRuler: true,
        contextmenu: false,
        domReadOnly: true,
      });

      // Track selection changes.
      editor.onDidChangeCursorSelection(function () {
        var selection = editor.getSelection();
        var hasSelection =
          selection !== null && !selection.isEmpty();
        postToNative({ type: "selectionChanged", hasSelection: hasSelection });
      });

      // Listen for theme changes.
      if (window.matchMedia) {
        window
          .matchMedia("(prefers-color-scheme: dark)")
          .addEventListener("change", function (e) {
            var theme = e.matches ? "vs-dark" : "vs";
            monaco.editor.setTheme(theme);
          });
      }

      postToNative({ type: "ready" });
    });
  }

  // Public API callable from Swift via evaluateJavaScript.
  window.cmuxEditor = {
    // Set file content in the normal (non-diff) editor.
    setContent: function (content, language, filePath) {
      currentLanguage = language || "plaintext";
      currentFilePath = filePath || "";

      if (isDiffMode && diffEditor) {
        diffEditor.dispose();
        diffEditor = null;
        isDiffMode = false;
        document.getElementById("editor-container").innerHTML = "";
        // Re-create the normal editor.
        editor = monaco.editor.create(
          document.getElementById("editor-container"),
          {
            value: content,
            language: currentLanguage,
            theme: detectTheme(),
            readOnly: true,
            automaticLayout: true,
            minimap: { enabled: true },
            scrollBeyondLastLine: false,
            fontSize: 12,
            fontFamily:
              '"SF Mono", Menlo, Monaco, "Courier New", monospace',
            lineNumbers: "on",
            renderWhitespace: "none",
            wordWrap: "off",
            folding: true,
            glyphMargin: false,
            largeFileOptimizations: true,
            maxTokenizationLineLength: 20000,
            scrollbar: {
              verticalScrollbarSize: 10,
              horizontalScrollbarSize: 10,
            },
            overviewRulerLanes: 0,
            hideCursorInOverviewRuler: true,
            contextmenu: false,
            domReadOnly: true,
          }
        );
        editor.onDidChangeCursorSelection(function () {
          var selection = editor.getSelection();
          var hasSelection =
            selection !== null && !selection.isEmpty();
          postToNative({
            type: "selectionChanged",
            hasSelection: hasSelection,
          });
        });
      } else if (editor) {
        var model = editor.getModel();
        if (model) {
          model.setValue(content);
          monaco.editor.setModelLanguage(model, currentLanguage);
        }
      }
    },

    // Enter diff mode: show original (base) vs modified (current).
    setDiffContent: function (original, modified, language) {
      var lang = language || currentLanguage;
      isDiffMode = true;

      if (editor) {
        editor.dispose();
        editor = null;
      }

      var container = document.getElementById("editor-container");
      container.innerHTML = "";

      var originalModel = monaco.editor.createModel(original, lang);
      var modifiedModel = monaco.editor.createModel(modified, lang);

      diffEditor = monaco.editor.createDiffEditor(container, {
        theme: detectTheme(),
        readOnly: true,
        automaticLayout: true,
        renderSideBySide: true,
        fontSize: 12,
        fontFamily:
          '"SF Mono", Menlo, Monaco, "Courier New", monospace',
        minimap: { enabled: false },
        scrollBeyondLastLine: false,
        glyphMargin: false,
        contextmenu: false,
        domReadOnly: true,
      });

      diffEditor.setModel({
        original: originalModel,
        modified: modifiedModel,
      });

      // Track selection on the modified side.
      var modifiedEditor = diffEditor.getModifiedEditor();
      modifiedEditor.onDidChangeCursorSelection(function () {
        var selection = modifiedEditor.getSelection();
        var hasSelection =
          selection !== null && !selection.isEmpty();
        postToNative({ type: "selectionChanged", hasSelection: hasSelection });
      });
    },

    // Get the currently selected text.
    getSelection: function () {
      var activeEditor = isDiffMode
        ? diffEditor
          ? diffEditor.getModifiedEditor()
          : null
        : editor;
      if (!activeEditor) return "";
      var selection = activeEditor.getSelection();
      if (!selection || selection.isEmpty()) return "";
      return activeEditor.getModel().getValueInRange(selection);
    },

    // Get all content.
    getContent: function () {
      var activeEditor = isDiffMode
        ? diffEditor
          ? diffEditor.getModifiedEditor()
          : null
        : editor;
      if (!activeEditor) return "";
      return activeEditor.getValue();
    },

    // Trigger send-selection flow: get selection and post to Swift.
    triggerSendSelection: function () {
      var text = window.cmuxEditor.getSelection();
      if (text) {
        postToNative({ type: "sendSelection", content: text });
      }
    },

    // Set theme explicitly from Swift.
    setTheme: function (isDark) {
      monaco.editor.setTheme(isDark ? "vs-dark" : "vs");
    },

    // Go to a specific line and column.
    goToLine: function (line, column) {
      var activeEditor = isDiffMode
        ? diffEditor
          ? diffEditor.getModifiedEditor()
          : null
        : editor;
      if (!activeEditor) return;
      var col = column || 1;
      activeEditor.revealLineInCenter(line);
      activeEditor.setPosition({ lineNumber: line, column: col });
    },
  };

  // Boot.
  initMonaco();
})();
