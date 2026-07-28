package cmux

import "testing"

func TestParseLayoutChangedExposesScreen(t *testing.T) {
	event := parseEvent(map[string]any{
		"event":  "layout-changed",
		"screen": float64(7),
	})
	layout, ok := event.(LayoutChangedEvent)
	if !ok {
		t.Fatalf("event type = %T, want LayoutChangedEvent", event)
	}
	if layout.Screen != 7 {
		t.Fatalf("screen = %d, want 7", layout.Screen)
	}
}

func TestParseTitleChangedIncludesAuthoritativeTitle(t *testing.T) {
	event := parseEvent(map[string]any{
		"event":   "title-changed",
		"surface": float64(7),
		"title":   "build logs",
	})
	title, ok := event.(TitleChangedEvent)
	if !ok {
		t.Fatalf("event type = %T, want TitleChangedEvent", event)
	}
	if title.Surface != 7 || title.Title == nil || *title.Title != "build logs" {
		t.Fatalf("event = %+v", title)
	}

	legacy, ok := parseEvent(map[string]any{
		"event":   "title-changed",
		"surface": float64(7),
	}).(TitleChangedEvent)
	if !ok || legacy.Title != nil {
		t.Fatalf("legacy event = %#v", legacy)
	}
}

func TestParseResizedAcceptsProtocolV6DataField(t *testing.T) {
	event, ok := parseEvent(map[string]any{
		"event":   "resized",
		"surface": float64(7),
		"cols":    float64(80),
		"rows":    float64(24),
		"data":    "cmVwbGF5",
	}).(ResizedEvent)
	if !ok {
		t.Fatalf("event type = %T, want ResizedEvent", event)
	}
	if event.Replay != "cmVwbGF5" {
		t.Fatalf("replay = %q, want protocol v6 data", event.Replay)
	}
}

func TestParseSurfaceResizeFailedExposesRetrySchedule(t *testing.T) {
	event, ok := parseEvent(map[string]any{
		"event":          "surface-resize-failed",
		"surface":        float64(7),
		"cols":           float64(120),
		"rows":           float64(40),
		"error":          "browser is not responding",
		"retry_after_ms": float64(250),
	}).(SurfaceResizeFailedEvent)
	if !ok || event.RetryAfterMS == nil || *event.RetryAfterMS != 250 {
		t.Fatalf("surface resize failure = %#v", event)
	}
}

func TestParseOverflowExposesRecoveryFields(t *testing.T) {
	event, ok := parseEvent(map[string]any{
		"event":   "overflow",
		"error":   "subscriber fell behind",
		"scope":   "surface",
		"surface": float64(7),
	}).(OverflowEvent)
	if !ok || event.Scope == nil || *event.Scope != "surface" || event.Surface == nil || *event.Surface != 7 {
		t.Fatalf("overflow event = %#v", event)
	}
}
