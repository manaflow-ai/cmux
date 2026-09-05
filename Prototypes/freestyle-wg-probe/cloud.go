package main

// Small native client for the parts of Freestyle used by the proof. It reads
// the same browser login that `freestyle` stores, and never prints credentials.

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"time"
)

const (
	stackAuthURL        = "https://api.stack-auth.com"
	stackProjectID      = "0edf478c-f123-46fb-818f-34c0024a9f35"
	stackPublishableKey = "pck_h2aft7g9pqjzrkdnzs199h1may5wjtdtdxeex7m2wzp1r"
	freestyleAPIURL     = "https://api.freestyle.sh"
)

// These indirections keep the auth and API paths testable without changing
// the production endpoints.
var stackAuthBaseURL = stackAuthURL
var freestyleAPIBaseURL = freestyleAPIURL

type savedFreestyleConfig struct {
	RefreshToken  string `json:"refreshToken"`
	ActiveTeamID  string `json:"activeTeamId"`
	DefaultTeamID string `json:"defaultTeamId"`
	Teams         []struct {
		TeamID string `json:"teamId"`
		Name   string `json:"name"`
	} `json:"teams"`
}

type cloudClient struct {
	http                *http.Client
	accessToken, teamID string
	refreshToken        string
	authMu              sync.Mutex
}

type cloudVM struct {
	ID          string      `json:"id"`
	Name        string      `json:"name"`
	DisplayName string      `json:"displayName"`
	Slug        string      `json:"slug"`
	State       string      `json:"state"`
	VPCs        []vmNetwork `json:"vpcs"`
	Networks    []vmNetwork `json:"networks"`
}

type vmNetwork struct {
	VPC   string `json:"vpc"`
	VPCID string `json:"vpcId"`
	IPv4  string `json:"ipv4"`
	CIDR  string `json:"cidr"`
}
type vmList struct {
	VMs        []cloudVM `json:"vms"`
	TotalCount int       `json:"totalCount"`
}

type tunnelResponse struct {
	ID           string `json:"id"`
	TunnelID     string `json:"tunnelId"`
	ClientConfig string `json:"clientConfig"`
	Attachments  []struct {
		VPCID string `json:"vpcId"`
		IPv4  string `json:"ipv4"`
		CIDR  string `json:"vpcCidr"`
	} `json:"attachments"`
}
type firewallResponse struct {
	ID string `json:"id"`
}

func readSavedFreestyleConfig() (savedFreestyleConfig, error) {
	path := freestyleConfigPath()
	b, err := osReadFile(path)
	if err != nil {
		return savedFreestyleConfig{}, errors.New("no saved Freestyle login found; run `freestyle login` first")
	}
	var c savedFreestyleConfig
	if json.Unmarshal(b, &c) != nil || c.RefreshToken == "" {
		return c, errors.New("saved Freestyle login is not usable; run `freestyle login` again")
	}
	return c, nil
}

// Variables make this file easy to test without replacing the OS home.
var osReadFile = func(path string) ([]byte, error) { return os.ReadFile(path) }
var freestyleConfigPath = func() string { home, _ := os.UserHomeDir(); return filepath.Join(home, ".freestyle", "config.json") }

func newCloudClient(ctx context.Context) (*cloudClient, error) {
	stored, err := readSavedFreestyleConfig()
	if err != nil {
		return nil, err
	}
	team := stored.ActiveTeamID
	if team == "" {
		team = stored.DefaultTeamID
	}
	if team == "" && len(stored.Teams) == 1 {
		team = stored.Teams[0].TeamID
	}
	if team == "" {
		return nil, errors.New("your Freestyle login has no selected team; run `freestyle team use <name-or-id>`")
	}
	client := &cloudClient{
		http:         &http.Client{Timeout: 2 * time.Minute},
		teamID:       team,
		refreshToken: stored.RefreshToken,
	}
	if err := client.refreshAccessToken(ctx); err != nil {
		return nil, err
	}
	return client, nil
}

// refreshAccessToken rotates the saved session token and obtains a fresh API
// access token. The mutex also prevents two cleanup requests from rotating the
// same refresh token at the same time.
func (c *cloudClient) refreshAccessToken(ctx context.Context) error {
	c.authMu.Lock()
	defer c.authMu.Unlock()
	// Another Freestyle CLI process may have rotated the refresh token. Read
	// the file again before retrying so a running connection can recover.
	if stored, err := readSavedFreestyleConfig(); err == nil && stored.RefreshToken != "" {
		c.refreshToken = stored.RefreshToken
	}
	request, err := http.NewRequestWithContext(ctx, http.MethodPost, stackAuthBaseURL+"/api/v1/auth/sessions/current/refresh", strings.NewReader("{}"))
	if err != nil {
		return err
	}
	request.Header.Set("Content-Type", "application/json")
	request.Header.Set("x-stack-project-id", stackProjectID)
	request.Header.Set("x-stack-publishable-client-key", stackPublishableKey)
	request.Header.Set("x-stack-access-type", "client")
	request.Header.Set("x-stack-refresh-token", c.refreshToken)
	response, err := http.DefaultClient.Do(request)
	if err != nil {
		return fmt.Errorf("refresh Freestyle login: %w", err)
	}
	defer response.Body.Close()
	if response.StatusCode/100 != 2 {
		return errors.New("your Freestyle login expired; run `freestyle login` again")
	}
	var token struct {
		AccessToken  string `json:"access_token"`
		RefreshToken string `json:"refresh_token"`
	}
	if err := json.NewDecoder(response.Body).Decode(&token); err != nil || token.AccessToken == "" {
		return errors.New("Freestyle login refresh returned no access token")
	}
	if token.RefreshToken != "" && token.RefreshToken != c.refreshToken {
		if err := saveRefreshToken(token.RefreshToken); err != nil {
			return fmt.Errorf("save refreshed Freestyle login: %w", err)
		}
		c.refreshToken = token.RefreshToken
	}
	c.accessToken = token.AccessToken
	return nil
}

func saveRefreshToken(token string) error {
	path := freestyleConfigPath()
	b, err := osReadFile(path)
	if err != nil {
		return err
	}
	var data map[string]any
	if err := json.Unmarshal(b, &data); err != nil {
		return err
	}
	data["refreshToken"] = token
	updated, err := json.MarshalIndent(data, "", "  ")
	if err != nil {
		return err
	}
	updated = append(updated, '\n')
	if err := os.WriteFile(path, updated, 0o600); err != nil {
		return err
	}
	return os.Chmod(path, 0o600)
}

func (c *cloudClient) request(ctx context.Context, method, path string, body any, out any) error {
	response, err := c.doWithRefresh(ctx, method, path, body)
	if err != nil {
		return err
	}
	resp := response.response
	if response.status == http.StatusAccepted { // background request: poll its id.
		var accepted struct {
			RequestID string `json:"requestId"`
			ResultURL string `json:"resultUrl"`
		}
		_ = json.NewDecoder(resp.Body).Decode(&accepted)
		resp.Body.Close()
		if accepted.RequestID == "" {
			accepted.RequestID = resp.Header.Get("x-freestyle-background-request-id")
		}
		pollPath := accepted.ResultURL
		if pollPath == "" && accepted.RequestID != "" {
			pollPath = "/v5/background-requests/" + urlPath(accepted.RequestID)
		}
		if pollPath == "" {
			return errors.New("Freestyle returned an incomplete background request")
		}
		for {
			select {
			case <-ctx.Done():
				return ctx.Err()
			case <-time.After(500 * time.Millisecond):
			}
			poll, e := c.doWithRefresh(ctx, http.MethodGet, pollPath, nil)
			if e != nil {
				return e
			}
			if poll.status == http.StatusAccepted {
				poll.body.Close()
				continue
			}
			resp = poll.response
			break
		}
	}
	defer resp.Body.Close()
	if resp.StatusCode/100 != 2 {
		data, _ := io.ReadAll(io.LimitReader(resp.Body, 4096))
		return fmt.Errorf("Freestyle API %s: %s", resp.Status, strings.TrimSpace(string(data)))
	}
	if out != nil {
		return json.NewDecoder(resp.Body).Decode(out)
	}
	return nil
}

type apiResponse struct {
	response *http.Response
	body     io.ReadCloser
	status   int
}

func (c *cloudClient) do(ctx context.Context, method, path string, body any) (apiResponse, error) {
	var reader io.Reader
	if body != nil {
		b, _ := json.Marshal(body)
		reader = strings.NewReader(string(b))
	}
	req, err := http.NewRequestWithContext(ctx, method, freestyleAPIBaseURL+path, reader)
	if err != nil {
		return apiResponse{}, err
	}
	c.authMu.Lock()
	accessToken := c.accessToken
	c.authMu.Unlock()
	req.Header.Set("Authorization", "Bearer "+accessToken)
	req.Header.Set("X-Freestyle-Team-Id", c.teamID)
	req.Header.Set("Content-Type", "application/json")
	resp, err := c.http.Do(req)
	if err != nil {
		return apiResponse{}, err
	}
	return apiResponse{response: resp, body: resp.Body, status: resp.StatusCode}, nil
}

func (c *cloudClient) doWithRefresh(ctx context.Context, method, path string, body any) (apiResponse, error) {
	response, err := c.do(ctx, method, path, body)
	if err != nil || response.status != http.StatusUnauthorized {
		return response, err
	}
	response.body.Close()
	if err := c.refreshAccessToken(ctx); err != nil {
		return apiResponse{}, err
	}
	return c.do(ctx, method, path, body)
}

func (c *cloudClient) listVMs(ctx context.Context) ([]cloudVM, error) {
	var result vmList
	err := c.request(ctx, http.MethodGet, "/v5/vms", nil, &result)
	return result.VMs, err
}
func (c *cloudClient) startVM(ctx context.Context, id string) error {
	return c.request(ctx, http.MethodPost, "/v5/vms/"+urlPath(id)+"/start", nil, nil)
}
func (c *cloudClient) exec(ctx context.Context, id, command string) (string, error) {
	var result struct {
		Stdout     string `json:"stdout"`
		Stderr     string `json:"stderr"`
		StatusCode *int   `json:"statusCode"`
	}
	err := c.request(ctx, http.MethodPost, "/v5/vms/"+urlPath(id)+"/exec-await", map[string]any{"command": command, "timeoutMs": 30000}, &result)
	if err != nil {
		return "", err
	}
	if result.StatusCode != nil && *result.StatusCode != 0 {
		return result.Stdout, fmt.Errorf("remote setup failed (exit %d): %s", *result.StatusCode, strings.TrimSpace(result.Stderr))
	}
	return result.Stdout, nil
}
func (c *cloudClient) createTunnel(ctx context.Context, publicKey, vpcID string) (tunnelResponse, error) {
	var result tunnelResponse
	err := c.request(ctx, http.MethodPost, "/v5/tunnels", map[string]any{"displayName": "userspace proof (temporary)", "clientPublicKey": publicKey, "routes": []string{"10.0.0.0/8", "fd00::/8"}, "vpcs": []map[string]string{{"vpcId": vpcID}}}, &result)
	return result, err
}
func (c *cloudClient) deleteTunnel(ctx context.Context, id string) error {
	return c.request(ctx, http.MethodDelete, "/v5/tunnels/"+urlPath(id), nil, nil)
}
func (c *cloudClient) createFirewall(ctx context.Context, tunnelID, vmID string, port int) (firewallResponse, error) {
	var result firewallResponse
	err := c.request(ctx, http.MethodPost, "/v5/firewall/rules", map[string]any{"action": "allow", "source": map[string]string{"tunnelId": tunnelID}, "destination": map[string]any{"vmId": vmID, "port": port, "protocol": "tcp"}, "description": "temporary userspace proof"}, &result)
	return result, err
}
func (c *cloudClient) deleteFirewall(ctx context.Context, id string) error {
	return c.request(ctx, http.MethodDelete, "/v5/firewall/rules/"+urlPath(id), nil, nil)
}
func urlPath(s string) string {
	return strings.ReplaceAll(strings.ReplaceAll(s, "/", "%2F"), "?", "%3F")
}
