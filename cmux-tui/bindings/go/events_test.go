package cmux

import "testing"

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
