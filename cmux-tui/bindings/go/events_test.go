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
