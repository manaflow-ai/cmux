package main

import (
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/charmbracelet/lipgloss"
	"github.com/charmbracelet/x/ansi"
)

func TestReplaceImagePathsUsesStableTokens(t *testing.T) {
	dir := t.TempDir()
	image := filepath.Join(dir, "dragged image.png")
	if err := osWriteFile(image, []byte("png"), 0o600); err != nil {
		t.Fatal(err)
	}

	m := initialModel(config{claudeCount: 1, codexCount: 1, useAIName: true})
	replaced, changed := m.replaceImagePaths(`look at "` + image + `" and ` + shellEscape(image))
	if !changed {
		t.Fatal("expected image path replacement")
	}
	if replaced != "look at [Image #1] and [Image #1]" {
		t.Fatalf("unexpected replacement: %q", replaced)
	}
	if len(m.images) != 1 {
		t.Fatalf("expected one attachment, got %d", len(m.images))
	}
	if m.images[0].Token != "[Image #1]" {
		t.Fatalf("unexpected token: %q", m.images[0].Token)
	}
}

func TestRenderInputFillsEveryLine(t *testing.T) {
	m := initialModel(config{claudeCount: 1, codexCount: 1, useAIName: true})
	m.resize(120, 40)

	out := m.renderInput(72)
	lines := strings.Split(out, "\n")
	expectedHeight := m.textarea.Height() + 2
	if len(lines) != expectedHeight {
		t.Fatalf("expected %d lines, got %d", expectedHeight, len(lines))
	}
	for index, line := range lines {
		if width := lipgloss.Width(line); width != 72 {
			t.Fatalf("line %d width = %d, want 72", index, width)
		}
	}
}

func TestRenderInputUsesTwoCellLeftInset(t *testing.T) {
	m := initialModel(config{claudeCount: 1, codexCount: 1, useAIName: true})
	m.resize(120, 40)

	out := m.renderInput(72)
	lines := strings.Split(out, "\n")
	if len(lines) < 2 {
		t.Fatalf("expected rendered input content, got %d lines", len(lines))
	}
	line := ansi.Strip(lines[1])
	if !strings.HasPrefix(line, "  What should") {
		t.Fatalf("expected two-cell left inset before placeholder, got %q", line[:min(len(line), 16)])
	}
}

func TestStartLaunchClearsPromptImmediatelyAndKeepsNextDraft(t *testing.T) {
	m := initialModel(config{cmuxPath: "cmux", claudeCount: 1, codexCount: 1, placement: "splits", isolation: "auto", useAIName: true})
	m.textarea.SetValue("ship this")
	m.images = []imageAttachment{{Token: "[Image #1]", Path: "/tmp/image.png", Name: "image.png"}}

	updated, _ := m.startLaunch()
	m = updated.(model)
	if value := m.textarea.Value(); value != "" {
		t.Fatalf("prompt should clear immediately, got %q", value)
	}
	if len(m.images) != 0 {
		t.Fatalf("images should clear immediately, got %d", len(m.images))
	}
	if m.pendingLaunches != 1 {
		t.Fatalf("pending launches = %d, want 1", m.pendingLaunches)
	}

	m.textarea.SetValue("next draft")
	updated, _ = m.Update(launchDoneMsg{output: "OK workspace:abc"})
	m = updated.(model)
	if value := m.textarea.Value(); value != "next draft" {
		t.Fatalf("launch completion should not clear next draft, got %q", value)
	}
	if m.pendingLaunches != 0 {
		t.Fatalf("pending launches after completion = %d, want 0", m.pendingLaunches)
	}
}

func osWriteFile(name string, data []byte, perm uint32) error {
	return os.WriteFile(name, data, os.FileMode(perm))
}

func shellEscape(path string) string {
	out := make([]rune, 0, len(path))
	for _, r := range path {
		if r == ' ' {
			out = append(out, '\\', ' ')
		} else {
			out = append(out, r)
		}
	}
	return string(out)
}
