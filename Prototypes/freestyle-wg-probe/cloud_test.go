package main

import (
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"path/filepath"
	"testing"
)

func TestCloudRequestRefreshesExpiredAccessToken(t *testing.T) {
	var apiCalls, refreshCalls int
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch r.URL.Path {
		case "/v5/test":
			apiCalls++
			if r.Header.Get("Authorization") != "Bearer fresh-access" {
				w.WriteHeader(http.StatusUnauthorized)
				return
			}
			w.Header().Set("Content-Type", "application/json")
			_, _ = w.Write([]byte(`{"ok":true}`))
		case "/api/v1/auth/sessions/current/refresh":
			refreshCalls++
			w.Header().Set("Content-Type", "application/json")
			_ = json.NewEncoder(w).Encode(map[string]string{
				"access_token":  "fresh-access",
				"refresh_token": "test-refresh",
			})
		default:
			http.NotFound(w, r)
		}
	}))
	defer server.Close()

	oldAuthURL, oldAPIURL := stackAuthBaseURL, freestyleAPIBaseURL
	oldReadFile, oldConfigPath := osReadFile, freestyleConfigPath
	stackAuthBaseURL, freestyleAPIBaseURL = server.URL, server.URL
	tmpConfig := filepath.Join(t.TempDir(), "config.json")
	osReadFile = func(string) ([]byte, error) {
		return []byte(`{"refreshToken":"test-refresh"}`), nil
	}
	freestyleConfigPath = func() string { return tmpConfig }
	t.Cleanup(func() {
		stackAuthBaseURL, freestyleAPIBaseURL = oldAuthURL, oldAPIURL
		osReadFile, freestyleConfigPath = oldReadFile, oldConfigPath
	})

	client := &cloudClient{
		http:         server.Client(),
		accessToken:  "expired-access",
		refreshToken: "test-refresh",
		teamID:       "team",
	}
	var result struct {
		OK bool `json:"ok"`
	}
	if err := client.request(context.Background(), http.MethodGet, "/v5/test", nil, &result); err != nil {
		t.Fatal(err)
	}
	if !result.OK {
		t.Fatal("response did not decode")
	}
	if apiCalls != 2 || refreshCalls != 1 {
		t.Fatalf("api calls = %d, refresh calls = %d; want 2 and 1", apiCalls, refreshCalls)
	}
}
