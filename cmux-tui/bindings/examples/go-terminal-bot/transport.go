package terminalbot

import (
	"context"
	"errors"
	"fmt"
	"io"
	"time"

	cmux "github.com/manaflow-ai/cmux/cmux-tui/bindings/go"
)

func (bot *Bot) client() (*cmux.Client, error) {
	return cmux.NewClient(cmux.Options{
		SocketPath: bot.config.SocketPath,
		Session:    bot.config.Session,
		Timeout:    bot.config.IOTimeout,
	})
}

func (bot *Bot) call(
	ctx context.Context,
	replaySafe bool,
	operation string,
	call func(*cmux.Client) error,
) error {
	attempts := 1
	if replaySafe {
		attempts += bot.config.RetryLimit
	}
	var lastErr error
	for attempt := 0; attempt < attempts; attempt++ {
		if attempt > 0 {
			if err := bot.waitRetry(ctx); err != nil {
				return err
			}
		}
		client, err := bot.client()
		if err == nil {
			var identity cmux.IdentifyResult
			identity, err = client.Identify(ctx)
			if err == nil && identity.Protocol < cmux.MuxProtocolVersion {
				err = fmt.Errorf(
					"%w: %s requires protocol %d, server uses %d",
					cmux.ErrProtocolMismatch,
					operation,
					cmux.MuxProtocolVersion,
					identity.Protocol,
				)
			}
			if err == nil {
				err = call(client)
			}
			closeErr := client.Close()
			if err == nil && closeErr != nil {
				err = closeErr
			}
		}
		if err == nil {
			return nil
		}
		if cause := context.Cause(ctx); cause != nil {
			return fmt.Errorf("%s: %w", operation, cause)
		}
		lastErr = err
		if !replaySafe || !isRetryable(err) {
			break
		}
	}
	return fmt.Errorf("%s: %w", operation, lastErr)
}

func (bot *Bot) openDeltaStream(ctx context.Context) (*cmux.Stream, error) {
	var stream *cmux.Stream
	err := bot.call(ctx, true, "subscribe to deltas", func(client *cmux.Client) error {
		var err error
		stream, err = client.SubscribeDeltas(ctx)
		return err
	})
	return stream, err
}

func (bot *Bot) openByteStream(ctx context.Context, surface cmux.ID) (*cmux.Stream, error) {
	var stream *cmux.Stream
	err := bot.call(ctx, true, "attach terminal bytes", func(client *cmux.Client) error {
		var err error
		stream, err = client.AttachSurfaceWithOptions(
			ctx,
			surface,
			cmux.AttachSurfaceOptions{Mode: cmux.AttachBytes},
		)
		return err
	})
	return stream, err
}

func (bot *Bot) waitRetry(ctx context.Context) error {
	if bot.config.RetryDelay == 0 {
		return context.Cause(ctx)
	}
	timer := time.NewTimer(bot.config.RetryDelay)
	defer timer.Stop()
	select {
	case <-ctx.Done():
		return context.Cause(ctx)
	case <-timer.C:
		return nil
	}
}

func isRetryable(err error) bool {
	return errors.Is(err, cmux.ErrConnection) ||
		errors.Is(err, cmux.ErrTimeout) ||
		errors.Is(err, io.EOF)
}
